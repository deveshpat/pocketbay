using System.Windows;
using System.Windows.Threading;
using Pocketbay.Emu;

namespace Pocketbay;

/// Turns keyboard/mouse input into multi-touch according to the active keymap. Each
/// control owns its own finger so move + aim + fire + scope can all be held at once.
/// Runs on the UI thread. Port of the Mac app's KeymapEngine.
public sealed class KeymapEngine
{
    public EmulatorClient? Client;
    Keymap _keymap;
    public Keymap Keymap { get => _keymap; set { _keymap = value; ReleaseAll(); } }
    public Size DeviceSize = new(1920, 1080);
    /// Maps a point on the shown picture to the emulator's touch space (rotation).
    public Func<Point, Point> ToNative = p => p;

    bool _active;
    /// Whether mapping applies right now (enabled + the mapped app is in front).
    public bool IsActive { get => _active; set { var was = _active; _active = value; if (was && !value) ReleaseAll(); } }
    public bool IsAiming { get; private set; }
    public event Action<bool>? AimingChanged;
    /// On-foot vs vehicle controls.
    public ControlMode Mode { get; private set; } = ControlMode.Foot;
    public event Action<ControlMode>? ModeChanged;
    /// Which controls each held input activated, so release lifts exactly those.
    readonly Dictionary<InputKey, List<string>> _activated = [];

    readonly HashSet<InputKey> _held = [];
    bool _joystickTouching;
    Point? _aimFinger, _lookFinger;
    bool _lookHeld;
    string? _aimPausedBy;
    bool _resumeAimOnRelease;
    readonly Dictionary<string, (DateTime Time, bool ResumeAim)> _holdStarted = [];
    double _pendingDx, _pendingDy;
    bool _flushScheduled;

    const int AimTouchId = 200, LookTouchId = 201;

    public KeymapEngine(Keymap keymap) { _keymap = keymap; }

    Control? AimControl => _keymap.Controls.FirstOrDefault(c => c.Type == ControlType.Aim);
    Control? LookControl => _keymap.Controls.FirstOrDefault(c => c.Type == ControlType.Look);
    int TouchId(Control c) => _keymap.Controls.IndexOf(c) + 1;
    bool WorksNow(Control c) => c.Mode == null || c.Mode == Mode;
    Point PointOf(Control c) => new(c.X * DeviceSize.Width, c.Y * DeviceSize.Height);

    /// Mouse buttons are only mapped while aiming, so the pointer works normally otherwise.
    bool Applies(InputKey input) => IsActive && (!input.IsMouse || IsAiming);

    static void After(double seconds, Action a)
    {
        var t = new DispatcherTimer(DispatcherPriority.Input) { Interval = TimeSpan.FromSeconds(seconds) };
        t.Tick += (_, _) => { t.Stop(); a(); };
        t.Start();
    }

    Touch Finger(int id, Point p, bool down)
    {
        var n = ToNative(p);
        return EmulatorClient.Finger(id, n.X, n.Y, down);
    }

    void TouchControl(Control c, Point p, bool down) => Client?.SendTouch(Finger(TouchId(c), p, down));

    void QuickTap(Control c)
    {
        TouchControl(c, PointOf(c), true);
        After(0.05, () => TouchControl(c, PointOf(c), false));
    }

    // ---- Input ----

    /// Returns true if the keymap consumed the input.
    public bool Press(InputKey input)
    {
        if (!Applies(input)) return false;
        if (input == _keymap.VehicleToggleKey && !_keymap.Controls.Any(c => c.Inputs().Contains(input)))
        {
            if (_held.Add(input)) SetMode(Mode == ControlMode.Foot ? ControlMode.Vehicle : ControlMode.Foot);
            return true;
        }
        var all = _keymap.Controls.Where(c => c.Inputs().Contains(input)).ToList();
        if (all.Count == 0) return false;
        if (!_held.Add(input)) return true;   // key repeat
        var controls = all.Where(WorksNow).ToList();
        _activated[input] = controls.Select(c => c.Id).ToList();
        Activate(controls);
        return true;
    }

    /// Puts fingers down for the given controls (a key press, or a mode change while held).
    void Activate(List<Control> controls)
    {
        foreach (var c in controls)
        {
            switch (c.Type)
            {
                case ControlType.Tap when c.HoldToOpen == true:
                {
                    var wasAiming = IsAiming;
                    if (c.ShowsCursor == true && wasAiming) SetAiming(false);
                    _holdStarted[c.Id] = (DateTime.Now, wasAiming && c.ShowsCursor == true);
                    QuickTap(c);
                    break;
                }
                case ControlType.Tap:
                case ControlType.Fire:
                    if (c.Type == ControlType.Fire && !IsAiming) continue;
                    if (c.ShowsCursor == true)
                    {
                        if (IsAiming) { SetAiming(false); _aimPausedBy = c.Id; }
                        else if (_aimPausedBy == c.Id) { _aimPausedBy = null; _resumeAimOnRelease = true; }
                    }
                    TouchControl(c, PointOf(c), true);
                    break;
                case ControlType.Joystick:
                    UpdateJoystick(c);
                    break;
                case ControlType.Aim:
                    SetAiming(!IsAiming);
                    break;
                case ControlType.Look:
                    if (IsAiming) { LiftAim(); _lookHeld = true; }
                    else TouchControl(c, PointOf(c), true);
                    break;
            }
        }
    }

    public bool Release(InputKey input)
    {
        if (!_held.Remove(input)) return false;
        var ids = _activated.Remove(input, out var list) ? list : [];
        var controls = _keymap.Controls.Where(c => ids.Contains(c.Id) || (c.Type == ControlType.Joystick && c.Inputs().Contains(input))).ToList();
        Deactivate(controls);
        if (controls.FirstOrDefault(c => c.SwitchesTo != null)?.SwitchesTo is { } action)
            After(0.2, () => SetMode(action switch   // after the tap lands
            {
                ModeSwitch.Foot => ControlMode.Foot,
                ModeSwitch.Vehicle => ControlMode.Vehicle,
                _ => Mode == ControlMode.Foot ? ControlMode.Vehicle : ControlMode.Foot,
            }));
        return true;
    }

    /// Lifts the fingers of the given controls.
    void Deactivate(List<Control> controls)
    {
        foreach (var c in controls)
        {
            switch (c.Type)
            {
                case ControlType.Tap when c.HoldToOpen == true:
                {
                    if (!_holdStarted.Remove(c.Id, out var hold)) continue;
                    var wait = Math.Max(0, 0.15 - (DateTime.Now - hold.Time).TotalSeconds);
                    After(Math.Max(wait, 0.001), () =>
                    {
                        QuickTap(c);
                        if (hold.ResumeAim) After(0.15, () => SetAiming(true));
                    });
                    break;
                }
                case ControlType.Tap:
                case ControlType.Fire:
                    TouchControl(c, PointOf(c), false);
                    if (_resumeAimOnRelease)
                    {
                        _resumeAimOnRelease = false;
                        After(0.15, () => SetAiming(true));
                    }
                    break;
                case ControlType.Joystick:
                    UpdateJoystick(c);
                    break;
                case ControlType.Look:
                    if (_lookHeld) EndLook(); else TouchControl(c, PointOf(c), false);
                    break;
            }
        }
    }

    /// Switches on-foot ↔ vehicle controls; keys still held are re-applied.
    public void SetMode(ControlMode mode)
    {
        if (mode == Mode) return;
        Mode = mode;
        foreach (var input in _held.ToList())
        {
            var ids = _activated.TryGetValue(input, out var l) ? l : [];
            var stale = _keymap.Controls.Where(c => ids.Contains(c.Id) && !WorksNow(c)).ToList();
            if (stale.Count > 0) Deactivate(stale);
            var fresh = _keymap.Controls.Where(c => c.Inputs().Contains(input) && WorksNow(c) && !ids.Contains(c.Id) && c.Type != ControlType.Aim).ToList();
            _activated[input] = ids.Where(id => !stale.Any(s => s.Id == id)).Concat(fresh.Select(c => c.Id)).ToList();
            if (fresh.Count > 0) Activate(fresh);
        }
        foreach (var c in _keymap.Controls.Where(c => c.Type == ControlType.Joystick)) UpdateJoystick(c);
        ModeChanged?.Invoke(mode);
    }

    /// Scroll mapping fires a quick tap.
    public bool Scroll(bool up)
    {
        var input = up ? InputKey.ScrollUp : InputKey.ScrollDown;
        if (!Applies(input) || !_keymap.Controls.Any(c => c.Inputs().Contains(input))) return false;
        Press(input);
        After(0.04, () => Release(input));
        return true;
    }

    /// Relative mouse motion while aiming. Accumulated and flushed at most every 4 ms so
    /// fast mice can't flood the emulator with touches.
    public void MouseMoved(double dx, double dy)
    {
        if (!IsAiming) return;
        _pendingDx += dx;
        _pendingDy += dy;
        if (_flushScheduled) return;
        _flushScheduled = true;
        // Runs after the input already queued has been processed (natural coalescing);
        // Windows timers tick every ~15 ms, far too coarse for aiming.
        Application.Current.Dispatcher.BeginInvoke(DispatcherPriority.Input, FlushAimMotion);
    }

    void FlushAimMotion()
    {
        _flushScheduled = false;
        double dx = _pendingDx, dy = _pendingDy;
        _pendingDx = _pendingDy = 0;
        if (!IsAiming || (dx == 0 && dy == 0)) return;
        if (_lookHeld && LookControl is { } look)
            _lookFinger = Drag(_lookFinger, PointOf(look), LookTouchId, dx, dy, look.Sensitivity ?? 1);
        else if (AimControl is { } aim)
            _aimFinger = Drag(_aimFinger, PointOf(aim), AimTouchId, dx, dy, aim.Sensitivity ?? 1);
    }

    /// Esc while a bag/map paused aim: close it (Android Back) and resume aiming.
    public bool EscapeFromPausedMenu()
    {
        if (!IsActive || _aimPausedBy == null) return false;
        _aimPausedBy = null;
        Client?.Press("GoBack");
        After(0.15, () => SetAiming(true));
        return true;
    }

    // ---- Behaviours ----

    void UpdateJoystick(Control c)
    {
        if (c.Keys is not { Count: 4 } dirs) return;
        bool up = _held.Contains(dirs[0]), left = _held.Contains(dirs[1]);
        bool down = _held.Contains(dirs[2]), right = _held.Contains(dirs[3]);
        double vx = (right ? 1 : 0) - (left ? 1 : 0), vy = (down ? 1 : 0) - (up ? 1 : 0);
        if (!WorksNow(c)) vx = vy = 0;
        var centre = PointOf(c);
        var id = TouchId(c);

        if (vx == 0 && vy == 0)
        {
            if (_joystickTouching) { Client?.SendTouch(Finger(id, centre, false)); _joystickTouching = false; }
            return;
        }
        var len = Math.Sqrt(vx * vx + vy * vy);
        vx /= len; vy /= len;
        var r = (c.Radius ?? 0.12) * DeviceSize.Height;
        if (c.BoostKey is { } boost && _held.Contains(boost) && up) r *= 1.9;   // past the ring = sprint
        var target = new Point(centre.X + vx * r, centre.Y + vy * r);

        // Separate events: Android merges updates to one finger within a single event.
        if (!_joystickTouching) { Client?.SendTouch(Finger(id, centre, true)); _joystickTouching = true; }
        Client?.SendTouch(Finger(id, target, true));
    }

    /// Moves a camera-drag finger; it may roam the anchor's half of the screen and only
    /// lifts and re-grabs at the anchor when it leaves that area.
    Point Drag(Point? current, Point anchor, int id, double dx, double dy, double sensitivity)
    {
        var scale = sensitivity * DeviceSize.Width / 1920 * 1.2;
        var p = current ?? anchor;
        if (current == null) Client?.SendTouch(Finger(id, p, true));
        var next = new Point(p.X + dx * scale, p.Y + dy * scale);

        double W = DeviceSize.Width, H = DeviceSize.Height;
        var area = anchor.X >= W / 2 ? new Rect(W * 0.36, H * 0.03, W * 0.61, H * 0.94) : new Rect(W * 0.03, H * 0.03, W * 0.61, H * 0.94);
        if (!area.Contains(next))
        {
            Client?.SendTouch(Finger(id, p, false));
            p = anchor;
            Client?.SendTouch(Finger(id, p, true));
            next = new Point(p.X + dx * scale, p.Y + dy * scale);
        }
        Client?.SendTouch(Finger(id, next, true));
        return next;
    }

    void LiftAim()
    {
        _pendingDx = _pendingDy = 0;
        if (_aimFinger is { } p) { Client?.SendTouch(Finger(AimTouchId, p, false)); _aimFinger = null; }
    }

    void EndLook()
    {
        if (_lookFinger is { } p) Client?.SendTouch(Finger(LookTouchId, p, false));
        _lookFinger = null;
        _lookHeld = false;
    }

    public void SetAiming(bool on)
    {
        if (on) _aimPausedBy = null;
        if (on == IsAiming || (on && AimControl == null)) return;
        IsAiming = on;
        if (!on)
        {
            LiftAim();
            EndLook();
            foreach (var input in _held.Where(i => i.IsMouse).ToList()) Release(input);
        }
        AimingChanged?.Invoke(on);
    }

    /// Lifts every finger and forgets held keys (focus loss, keymap change).
    public void ReleaseAll()
    {
        foreach (var input in _held.ToList()) Release(input);
        _held.Clear();
        _activated.Clear();
        SetAiming(false);
        LiftAim();
        EndLook();
    }
}
