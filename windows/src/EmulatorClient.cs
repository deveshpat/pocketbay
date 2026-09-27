using System.Net.Http;
using System.Threading.Channels;
using Google.Protobuf;
using Google.Protobuf.WellKnownTypes;
using Grpc.Core;
using Grpc.Net.Client;
using Pocketbay.Emu;

namespace Pocketbay;

/// One screen frame: RGBA8888 pixels, rows top-down.
public sealed record Frame(int Width, int Height, ByteString Pixels, int QuarterTurns);

/// Talks to the emulator's gRPC endpoint. Input uses its own HTTP/2 connection so key
/// presses never queue behind 8 MB screen frames.
public sealed class EmulatorClient : IDisposable
{
    readonly GrpcChannel _media;
    readonly GrpcChannel _input;
    readonly EmulatorController.EmulatorControllerClient _emu;
    readonly EmulatorController.EmulatorControllerClient _inputEmu;
    readonly Metadata _auth;
    readonly Channel<InputEvent> _inputQueue = System.Threading.Channels.Channel.CreateUnbounded<InputEvent>(
        new UnboundedChannelOptions { SingleReader = true });
    readonly CancellationTokenSource _cts = new();

    public EmulatorClient(int port, string token)
    {
        GrpcChannel Make() => GrpcChannel.ForAddress($"http://127.0.0.1:{port}", new GrpcChannelOptions
        {
            MaxReceiveMessageSize = 32 * 1024 * 1024,
            MaxSendMessageSize = 4 * 1024 * 1024,
            HttpHandler = new SocketsHttpHandler { EnableMultipleHttp2Connections = true },
        });
        _media = Make();
        _input = Make();
        _emu = new EmulatorController.EmulatorControllerClient(_media);
        _inputEmu = new EmulatorController.EmulatorControllerClient(_input);
        _auth = new Metadata { { "authorization", "Bearer " + token } };
    }

    public void Dispose()
    {
        _cts.Cancel();
        _inputQueue.Writer.TryComplete();
        _media.Dispose();
        _input.Dispose();
    }

    // ---- Status ----

    public async Task<bool> IsBootedAsync()
    {
        try { return (await _emu.getStatusAsync(new Empty(), _auth, deadline: DateTime.UtcNow.AddSeconds(3))).Booted; }
        catch { return false; }
    }

    // ---- Screen ----

    /// Streams frames until cancelled or the stream ends.
    public async Task StreamScreenAsync(Action<Frame> onFrame, CancellationToken ct)
    {
        var format = new ImageFormat { Format = ImageFormat.Types.ImgFormat.Rgba8888 };
        using var call = _emu.streamScreenshot(format, _auth, cancellationToken: ct);
        await foreach (var img in call.ResponseStream.ReadAllAsync(ct))
        {
            int w = (int)img.Format.Width, h = (int)img.Format.Height;
            if (w <= 0 || h <= 0 || img.Image_.Length < w * h * 4) continue;
            var turns = img.Format.Rotation == null ? 0 : (int)img.Format.Rotation.Rotation_ & 3;
            onFrame(new Frame(w, h, img.Image_, turns));
        }
    }

    // ---- Audio ----

    /// Android's audio as 48 kHz stereo signed 16-bit PCM.
    public async Task StreamAudioAsync(Action<byte[]> onPcm, CancellationToken ct)
    {
        var fmt = new AudioFormat
        {
            SamplingRate = 48000,
            Channels = AudioFormat.Types.Channels.Stereo,
            Format = AudioFormat.Types.SampleFormat.AudFmtS16,
            Mode = AudioFormat.Types.DeliveryMode.ModeRealTime,
        };
        using var call = _emu.streamAudio(fmt, _auth, cancellationToken: ct);
        await foreach (var packet in call.ResponseStream.ReadAllAsync(ct))
            if (packet.Audio.Length > 0) onPcm(packet.Audio.ToByteArray());
    }

    // ---- Input ----

    /// Opens the long-lived input stream; reconnects if it drops.
    public void StartInputStream()
    {
        var ct = _cts.Token;
        _ = Task.Run(async () =>
        {
            while (!ct.IsCancellationRequested)
            {
                try
                {
                    using var call = _inputEmu.streamInputEvent(_auth, cancellationToken: ct);
                    await foreach (var ev in _inputQueue.Reader.ReadAllAsync(ct))
                        await call.RequestStream.WriteAsync(ev, ct);
                    return;
                }
                catch (Exception e) when (!ct.IsCancellationRequested)
                {
                    Log.Write("input stream: " + e.Message);
                    await Task.Delay(500, ct).ContinueWith(_ => { });
                }
            }
        }, ct);
    }

    public void Send(InputEvent ev) => _inputQueue.Writer.TryWrite(ev);

    public static Emu.Touch Finger(int id, double x, double y, bool down) => new()
    {
        Identifier = id, X = (int)x, Y = (int)y, Pressure = down ? 1 : 0,
        Expiration = Touch.Types.EventExpiration.NeverExpire,
    };

    public void SendTouch(params Emu.Touch[] touches)
    {
        var te = new TouchEvent();
        te.Touches.Add(touches);
        Send(new InputEvent { TouchEvent = te });
    }

    public void Key(int macKeyCode, bool down)
    {
        var k = new KeyboardEvent { EventType = down ? KeyboardEvent.Types.KeyEventType.Keydown : KeyboardEvent.Types.KeyEventType.Keyup };
        if (macKeyCode == 0)
        {
            // kVK_ANSI_A is 0, which proto3 treats as "unset"; send evdev KEY_A instead.
            k.CodeType = KeyboardEvent.Types.KeyCodeType.Evdev;
            k.KeyCode = 30;
        }
        else
        {
            k.CodeType = KeyboardEvent.Types.KeyCodeType.Mac;
            k.KeyCode = macKeyCode;
        }
        Send(new InputEvent { KeyEvent = k });
    }

    /// W3C key names; Android specials: GoBack, GoHome, AppSwitch, AudioVolumeUp/Down.
    public void Press(string key) =>
        Send(new InputEvent { KeyEvent = new KeyboardEvent { EventType = KeyboardEvent.Types.KeyEventType.Keypress, Key = key } });

    public void Wheel(int dx, int dy) => Send(new InputEvent { WheelEvent = new WheelEvent { Dx = dx, Dy = dy } });

    // ---- Clipboard ----

    public async Task<string?> GetClipboardAsync()
    {
        try { return (await _emu.getClipboardAsync(new Empty(), _auth)).Text; } catch { return null; }
    }

    public async Task SetClipboardAsync(string text)
    {
        try { await _emu.setClipboardAsync(new ClipData { Text = text }, _auth); } catch { }
    }

    public async Task StreamClipboardAsync(Action<string> onText, CancellationToken ct)
    {
        using var call = _emu.streamClipboard(new Empty(), _auth, cancellationToken: ct);
        await foreach (var clip in call.ResponseStream.ReadAllAsync(ct)) onText(clip.Text);
    }

    // ---- Device ----

    public async Task SetRotationAsync(float zDegrees)
    {
        var v = new PhysicalModelValue { Target = PhysicalModelValue.Types.PhysicalType.Rotation, Value = new ParameterValue() };
        v.Value.Data.Add(new[] { 0f, 0f, zDegrees });
        try { await _emu.setPhysicalModelAsync(v, _auth); } catch { }
    }
}
