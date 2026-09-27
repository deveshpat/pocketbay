using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;
using NAudio.Wave;

namespace Pocketbay;

/// Plays Android's audio on the current Windows output device, and moves to the new
/// default device whenever it changes (headphones plugged in, output switched…).
public sealed class AudioPlayer : IDisposable, IMMNotificationClient
{
    readonly WaveFormat _format = new(48000, 16, 2);
    readonly object _gate = new();
    readonly MMDeviceEnumerator _devices = new();
    BufferedWaveProvider? _buffer;
    WasapiOut? _out;

    /// Keep latency low: drop queued audio beyond this.
    static readonly TimeSpan MaxQueued = TimeSpan.FromMilliseconds(120);

    public AudioPlayer()
    {
        _devices.RegisterEndpointNotificationCallback(this);
        Restart();
    }

    void Restart()
    {
        lock (_gate)
        {
            try { _out?.Stop(); _out?.Dispose(); } catch { }
            _out = null;
            try
            {
                _buffer = new BufferedWaveProvider(_format) { DiscardOnBufferOverflow = true, BufferDuration = TimeSpan.FromMilliseconds(500) };
                var device = _devices.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
                _out = new WasapiOut(device, AudioClientShareMode.Shared, true, 40);
                _out.Init(_buffer);
                _out.Play();
                Log.Write("audio output: " + device.FriendlyName);
            }
            catch (Exception e) { Log.Write("audio failed: " + e.Message); }
        }
    }

    public void Enqueue(byte[] pcm)
    {
        lock (_gate)
        {
            if (_buffer == null) return;
            if (_buffer.BufferedDuration > MaxQueued) _buffer.ClearBuffer();
            _buffer.AddSamples(pcm, 0, pcm.Length);
        }
    }

    public void Dispose()
    {
        try { _devices.UnregisterEndpointNotificationCallback(this); } catch { }
        lock (_gate) { try { _out?.Stop(); _out?.Dispose(); } catch { } }
    }

    // Default output changed → rebind (off the notification thread, as Windows requires).
    public void OnDefaultDeviceChanged(DataFlow flow, Role role, string defaultDeviceId)
    {
        if (flow == DataFlow.Render && role == Role.Multimedia) Task.Run(Restart);
    }
    public void OnDeviceStateChanged(string deviceId, DeviceState newState) { }
    public void OnDeviceAdded(string pwstrDeviceId) { }
    public void OnDeviceRemoved(string deviceId) { }
    public void OnPropertyValueChanged(string pwstrDeviceId, PropertyKey key) { }
}
