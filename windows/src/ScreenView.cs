using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace Pocketbay;

/// Shows the Android screen and turns PC input into touches / keys / keymap actions.
public sealed class ScreenView : FrameworkElement
{
    public EmulatorClient? Client;
    public KeymapEngine Engine = null!;

    public Size DeviceSize { get; private set; } = new(1920, 1080);
    /// Quarter turns of the current picture; touches go in the unrotated space.
    public int QuarterTurns { get; private set; }
    public event Action<Size>? DeviceSizeChanged;
    public event Action? FirstFrame;
    public event Action<string[]>? FilesDropped;

    WriteableBitmap? _bmp;
    Frame? _pending, _last;
    bool _presentScheduled;
    readonly object _gate = new();
    bool _hasFrame;

    bool _pointerDown;
    readonly HashSet<int> _androidKeysDown = [];
    const int PointerId = 0;

    public ScreenView()
    {
        Focusable = true;
        AllowDrop = true;
        ClipToBounds = true;
        Cursor = Cursors.Arrow;
    }

    /// Aspect-fit rectangle the Android screen occupies inside this view.
    public Rect ScreenRect
    {
        get
        {
            double bw = ActualWidth, bh = ActualHeight;
            if (bw <= 0 || bh <= 0) return new Rect(0, 0, bw, bh);
            var aspect = DeviceSize.Width / DeviceSize.Height;
            double w = bw, h = bw / aspect;
            if (h > bh) { h = bh; w = h * aspect; }
            return new Rect(Math.Round((bw - w) / 2), Math.Round((bh - h) / 2), Math.Round(w), Math.Round(h));
        }
    }

    protected override void OnRender(DrawingContext dc)
    {
        dc.DrawRectangle(Brushes.Black, null, new Rect(0, 0, ActualWidth, ActualHeight));
        if (_bmp != null) dc.DrawImage(_bmp, ScreenRect);
    }

    protected override void OnRenderSizeChanged(SizeChangedInfo info)
    {
        base.OnRenderSizeChanged(info);
        InvalidateVisual();
    }

    // ---- Frames ----

    /// Called from the gRPC stream (any thread); coalesces to one UI-thread present at a time.
    public void FrameArrived(Frame frame)
    {
        lock (_gate)
        {
            _pending = frame;
            if (_presentScheduled) return;
            _presentScheduled = true;
        }
        Dispatcher.BeginInvoke(DispatcherPriority.Render, Present);
    }

    unsafe void Present()
    {
        Frame? f;
        lock (_gate) { f = _pending; _pending = null; _presentScheduled = false; }
        if (f == null) return;

        QuarterTurns = f.QuarterTurns;
        var size = new Size(f.Width, f.Height);
        var needsRedraw = !_hasFrame;
        if (_bmp == null || _bmp.PixelWidth != f.Width || _bmp.PixelHeight != f.Height)
        {
            needsRedraw = true;
            _bmp = new WriteableBitmap(f.Width, f.Height, 96, 96, PixelFormats.Bgra32, null);
            RenderOptions.SetBitmapScalingMode(this, BitmapScalingMode.Linear);
        }
        if (size != DeviceSize)
        {
            DeviceSize = size;
            Engine.DeviceSize = size;
            DeviceSizeChanged?.Invoke(size);
        }

        _bmp.Lock();
        try
        {
            var src = f.Pixels.Span;
            var dst = (uint*)_bmp.BackBuffer;
            int stride = _bmp.BackBufferStride / 4, w = f.Width, h = f.Height;
            fixed (byte* sp = src)
            {
                var s = (uint*)sp;
                for (int y = 0; y < h; y++)
                {
                    uint* d = dst + y * stride, row = s + y * w;
                    for (int x = 0; x < w; x++)
                    {
                        uint v = row[x];   // RGBA bytes → BGRA, opaque
                        d[x] = 0xFF000000u | ((v & 0xFFu) << 16) | (v & 0xFF00u) | ((v >> 16) & 0xFFu);
                    }
                }
            }
            _bmp.AddDirtyRect(new Int32Rect(0, 0, w, h));
        }
        finally { _bmp.Unlock(); }
        _last = f;

        if (needsRedraw) InvalidateVisual();
        if (!_hasFrame)
        {
            _hasFrame = true;
            FirstFrame?.Invoke();
        }
    }

    public void ResetForNewSession()
    {
        _hasFrame = false;
        _last = null;
        _pointerDown = false;
        _androidKeysDown.Clear();
    }

    public void SaveScreenshot(string path)
    {
        if (_bmp == null) return;
        var enc = new PngBitmapEncoder();
        enc.Frames.Add(BitmapFrame.Create(_bmp.Clone()));
        using var fs = File.Create(path);
        enc.Save(fs);
    }

    // ---- Coordinates ----

    Point DevicePoint(Point p)
    {
        var r = ScreenRect;
        var x = (p.X - r.X) / r.Width * DeviceSize.Width;
        var y = (p.Y - r.Y) / r.Height * DeviceSize.Height;
        return new Point(Math.Clamp(x, 0, DeviceSize.Width - 1), Math.Clamp(y, 0, DeviceSize.Height - 1));
    }

    /// Point on the shown picture → emulator's native (unrotated) touch space.
    public Point ToNative(Point p)
    {
        var odd = QuarterTurns % 2 == 1;
        double nw = odd ? DeviceSize.Height : DeviceSize.Width, nh = odd ? DeviceSize.Width : DeviceSize.Height;
        return QuarterTurns switch
        {
            1 => new Point(nw - p.Y, p.X),
            2 => new Point(nw - p.X, nh - p.Y),
            3 => new Point(p.Y, nh - p.X),
            _ => p,
        };
    }

    void TouchPointer(Point devicePt, bool down)
    {
        var n = ToNative(devicePt);
        Client?.SendTouch(EmulatorClient.Finger(PointerId, n.X, n.Y, down));
    }

    // ---- Mouse ----

    static int ButtonNumber(MouseButton b) => b switch
    {
        MouseButton.Left => 0, MouseButton.Right => 1, MouseButton.Middle => 2, MouseButton.XButton1 => 3, _ => 4,
    };

    protected override void OnMouseDown(MouseButtonEventArgs e)
    {
        Focus();
        e.Handled = true;
        if (Engine.Press(InputKey.Mouse(ButtonNumber(e.ChangedButton)))) return;
        if (e.ChangedButton != MouseButton.Left || Engine.IsAiming) return;
        _pointerDown = true;
        CaptureMouse();
        TouchPointer(DevicePoint(e.GetPosition(this)), true);
    }

    protected override void OnMouseUp(MouseButtonEventArgs e)
    {
        e.Handled = true;
        if (Engine.Release(InputKey.Mouse(ButtonNumber(e.ChangedButton)))) return;
        if (e.ChangedButton != MouseButton.Left || !_pointerDown) return;
        _pointerDown = false;
        if (!Engine.IsAiming) ReleaseMouseCapture();
        TouchPointer(DevicePoint(e.GetPosition(this)), false);
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        if (Engine.IsAiming) { AimMove(); return; }
        if (_pointerDown) TouchPointer(DevicePoint(e.GetPosition(this)), true);
    }

    protected override void OnMouseWheel(MouseWheelEventArgs e)
    {
        e.Handled = true;
        if (Engine.IsAiming) { Engine.Scroll(e.Delta > 0); return; }
        Client?.Wheel(0, e.Delta > 0 ? 120 : -120);
    }

    // ---- Mouse aim: hidden cursor, re-centred after every move ----

    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern bool ClipCursor(ref RECT r);
    [DllImport("user32.dll", EntryPoint = "ClipCursor")] static extern bool ClipCursorNone(IntPtr zero);
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

    POINT _aimCenter;
    bool _captured;

    public void SetCursorCaptured(bool captured)
    {
        if (captured == _captured) return;
        _captured = captured;
        if (captured)
        {
            var r = ScreenRect;
            var tl = PointToScreen(r.TopLeft);
            var br = PointToScreen(r.BottomRight);
            var c = PointToScreen(new Point(r.X + r.Width / 2, r.Y + r.Height / 2));
            _aimCenter = new POINT { X = (int)c.X, Y = (int)c.Y };
            var clip = new RECT { Left = (int)tl.X, Top = (int)tl.Y, Right = (int)br.X, Bottom = (int)br.Y };
            ClipCursor(ref clip);
            SetCursorPos(_aimCenter.X, _aimCenter.Y);
            CaptureMouse();
            Cursor = Cursors.None;
        }
        else
        {
            ClipCursorNone(IntPtr.Zero);
            Cursor = Cursors.Arrow;
            if (!_pointerDown) ReleaseMouseCapture();
        }
    }

    void AimMove()
    {
        if (!_captured || !GetCursorPos(out var p)) return;
        int dx = p.X - _aimCenter.X, dy = p.Y - _aimCenter.Y;
        if (dx == 0 && dy == 0) return;
        SetCursorPos(_aimCenter.X, _aimCenter.Y);
        Engine.MouseMoved(dx, dy);
    }

    // ---- Keyboard (forwarded by the window) ----

    public void HandleKeyDown(Key key, bool isRepeat)
    {
        if (key == Key.Escape)
        {
            if (Engine.IsAiming) Engine.SetAiming(false);
            else if (!isRepeat && !Engine.EscapeFromPausedMenu()) Client?.Press("GoBack");
            return;
        }
        if (InputKey.FromWpf(key) is not { } mac) return;
        if (Engine.Press(InputKey.KeyCode(mac))) return;
        if (isRepeat && _androidKeysDown.Contains(mac)) { Client?.Key(mac, true); return; }
        _androidKeysDown.Add(mac);
        Client?.Key(mac, true);
    }

    public void HandleKeyUp(Key key)
    {
        if (InputKey.FromWpf(key) is not { } mac) return;
        if (Engine.Release(InputKey.KeyCode(mac))) return;
        if (_androidKeysDown.Remove(mac)) Client?.Key(mac, false);
    }

    /// Presses Ctrl+<key> in Android (Mac key codes).
    public void SendControlShortcut(int macKeyCode)
    {
        Client?.Key(59, true);
        Client?.Key(macKeyCode, true);
        Client?.Key(macKeyCode, false);
        Client?.Key(59, false);
    }

    /// Lifts every finger and key; used when the window loses focus.
    public void ReleaseAllInput()
    {
        Engine.ReleaseAll();
        SetCursorCaptured(false);
        if (_pointerDown) { TouchPointer(new Point(0, 0), false); _pointerDown = false; ReleaseMouseCapture(); }
        foreach (var k in _androidKeysDown) Client?.Key(k, false);
        _androidKeysDown.Clear();
    }

    // ---- Drag & drop APKs ----

    static string[] Apks(DragEventArgs e) =>
        e.Data.GetData(DataFormats.FileDrop) is string[] files
            ? files.Where(f => f.EndsWith(".apk", StringComparison.OrdinalIgnoreCase)).ToArray()
            : [];

    protected override void OnDragOver(DragEventArgs e)
    {
        e.Effects = Apks(e).Length > 0 ? DragDropEffects.Copy : DragDropEffects.None;
        e.Handled = true;
    }

    protected override void OnDrop(DragEventArgs e)
    {
        var apks = Apks(e);
        if (apks.Length > 0) FilesDropped?.Invoke(apks);
    }
}
