using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;

namespace Pocketbay;

public enum OverlayMode { Hidden, Play, Edit }

/// Draws the mapped controls over the game. In edit mode it becomes interactive:
/// drag to move, click to change keys, add/remove controls.
public sealed class KeymapOverlay : Grid
{
    readonly OverlayCanvas _canvas;
    readonly Border _toolbar;
    readonly StackPanel _toolbarButtons;
    readonly Popup _popup = new() { StaysOpen = false, AllowsTransparency = true, Placement = PlacementMode.Relative };
    OverlayMode _mode = OverlayMode.Hidden;
    ContentControl _vehicleKeyHost = null!;

    public Func<Rect> ScreenRect = () => Rect.Empty;
    public Keymap Keymap { get => _canvas.Keymap; set { _canvas.Keymap = value; _canvas.InvalidateVisual(); } }
    public bool IsAiming { set { _canvas.IsAiming = value; _canvas.InvalidateVisual(); } }
    public ControlMode ControlMode { set { _canvas.Mode = value; _canvas.InvalidateVisual(); } }
    public void Refresh() => _canvas.InvalidateVisual();
    public event Action<Keymap>? Changed;
    public event Action? Done;
    /// Shown at the start of the editor toolbar (the layout picker).
    public UIElement? ToolbarAccessory { set { if (value != null) _toolbarButtons.Children.Insert(0, value); } }

    public OverlayMode Mode
    {
        get => _mode;
        set
        {
            _mode = value;
            Visibility = value == OverlayMode.Hidden ? Visibility.Collapsed : Visibility.Visible;
            IsHitTestVisible = value == OverlayMode.Edit;
            _toolbar.Visibility = value == OverlayMode.Edit ? Visibility.Visible : Visibility.Collapsed;
            _canvas.Editing = value == OverlayMode.Edit;
            _canvas.SelectedId = null;
            _popup.IsOpen = false;
            _canvas.InvalidateVisual();
            if (value == OverlayMode.Edit)
                _vehicleKeyHost.Content = new KeyCaptureButton(Keymap.VehicleToggleKey, k => { Keymap.VehicleToggleKey = k; Changed?.Invoke(Keymap); }) { MinWidth = 90 };
            if (value == OverlayMode.Edit)
                Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Input, () => _canvas.Focus());
        }
    }

    public KeymapOverlay()
    {
        _canvas = new OverlayCanvas(this);
        Children.Add(_canvas);

        _toolbarButtons = new StackPanel { Orientation = Orientation.Horizontal };
        Button Add(string title, ControlType type)
        {
            var b = ToolButton("+ " + title);
            b.ToolTip = $"Add {type.Title().ToLowerInvariant()}";
            b.Click += (_, _) => AddControl(type, null);
            return b;
        }
        var reset = ToolButton("Reset");
        reset.ToolTip = "Put this layout's buttons back to the BGMI Layout 2 defaults";
        reset.Click += (_, _) =>
        {
            var fresh = Keymap.Bgmi();
            fresh.Id = Keymap.Id;
            fresh.Name = Keymap.Name;
            Keymap = fresh;
            _canvas.SelectedId = null;
            Changed?.Invoke(Keymap);
        };
        var done = ToolButton("Done");
        done.FontWeight = FontWeights.SemiBold;
        done.Background = Glyph.Accent;
        done.Click += (_, _) => Done?.Invoke();
        foreach (var b in new[] { Add("Button", ControlType.Tap), Add("Joystick", ControlType.Joystick), Add("Aim", ControlType.Aim),
                     Add("Fire", ControlType.Fire), Add("Free look", ControlType.Look) })
            _toolbarButtons.Children.Add(b);
        _toolbarButtons.Children.Add(new TextBlock { Text = "Vehicle toggle:", Foreground = Brushes.Gray, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 4, 0) });
        _vehicleKeyHost = new ContentControl();
        _toolbarButtons.Children.Add(_vehicleKeyHost);
        _toolbarButtons.Children.Add(reset);
        _toolbarButtons.Children.Add(done);

        var hint = new TextBlock
        {
            Text = "Drag to move · Click to change its key · Double-click empty space to add a button · Esc when done",
            Foreground = new SolidColorBrush(Color.FromRgb(0xB0, 0xB0, 0xB0)), FontSize = 11, Margin = new Thickness(2, 6, 2, 0),
        };
        _toolbar = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(0xEE, 0x22, 0x22, 0x22)),
            CornerRadius = new CornerRadius(10), Padding = new Thickness(10, 8, 10, 8),
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 12, 0, 0), Visibility = Visibility.Collapsed,
            Child = new StackPanel { Children = { _toolbarButtons, hint } },
        };
        Children.Add(_toolbar);
        _popup.PlacementTarget = _canvas;
        Mode = OverlayMode.Hidden;
    }

    public static Button ToolButton(string text) => new()
    {
        Content = text, Margin = new Thickness(3, 0, 3, 0), Padding = new Thickness(10, 4, 10, 4),
        Foreground = Brushes.White, Background = new SolidColorBrush(Color.FromRgb(0x3A, 0x3A, 0x3A)),
        BorderBrush = new SolidColorBrush(Color.FromRgb(0x55, 0x55, 0x55)), Cursor = Cursors.Hand,
    };

    void AddControl(ControlType type, Point? at)
    {
        var r = ScreenRect();
        var p = at ?? new Point(r.X + r.Width / 2, r.Y + r.Height / 2);
        var c = Control.New(type, (p.X - r.X) / r.Width, (p.Y - r.Y) / r.Height);
        Keymap.Controls.Add(c);
        _canvas.SelectedId = c.Id;
        _canvas.InvalidateVisual();
        Changed?.Invoke(Keymap);
        ShowInspector(c);
    }

    internal void AddTapAt(Point p) => AddControl(ControlType.Tap, p);

    internal void RaiseChanged() => Changed?.Invoke(Keymap);

    internal void RaiseDone() => Done?.Invoke();

    internal void Remove(string id)
    {
        Keymap.Controls.RemoveAll(c => c.Id == id);
        _canvas.SelectedId = null;
        _popup.IsOpen = false;
        _canvas.InvalidateVisual();
        Changed?.Invoke(Keymap);
    }

    internal void ClosePopup() => _popup.IsOpen = false;

    internal void ShowInspector(Control c)
    {
        var inspector = new ControlInspector(c);
        inspector.Changed += () => { _canvas.InvalidateVisual(); Changed?.Invoke(Keymap); };
        inspector.RemoveRequested += () => Remove(c.Id);
        _popup.Child = inspector;
        var p = _canvas.CenterOf(c);
        _popup.HorizontalOffset = p.X + 28;
        _popup.VerticalOffset = Math.Max(0, p.Y - 40);
        _popup.IsOpen = true;
    }
}

/// The drawing + edit interaction surface.
sealed class OverlayCanvas : FrameworkElement
{
    readonly KeymapOverlay _owner;
    public Keymap Keymap = Keymap.Bgmi();
    public bool Editing, IsAiming;
    public ControlMode Mode = ControlMode.Foot;
    public string? SelectedId;
    Vector? _dragOffset;
    bool _dragMoved;

    public OverlayCanvas(KeymapOverlay owner) { _owner = owner; Focusable = true; }

    Rect R => _owner.ScreenRect();
    public Point CenterOf(Control c) { var r = R; return new Point(r.X + c.X * r.Width, r.Y + c.Y * r.Height); }
    double JoystickRadius(Control c) => (c.Radius ?? 0.12) * R.Height;

    Control? ControlAt(Point p) => Keymap.Controls.AsEnumerable().Reverse().FirstOrDefault(c =>
    {
        var d = (p - CenterOf(c)).Length;
        return c.Type == ControlType.Joystick ? d < JoystickRadius(c) + 14 : d < 26;
    });

    protected override void OnRender(DrawingContext dc)
    {
        var r = R;
        // Transparent fill so the whole area receives mouse input while editing.
        dc.DrawRectangle(Editing ? new SolidColorBrush(Color.FromArgb(0x73, 0, 0, 0)) : Brushes.Transparent, null, new Rect(0, 0, ActualWidth, ActualHeight));
        var dim = !Editing;
        var white = new SolidColorBrush(Color.FromArgb(0xF2, 255, 255, 255));
        foreach (var c in Keymap.Controls)
        {
            if (!Editing && IsAiming && c.Type is ControlType.Aim or ControlType.Look) continue;
            if (!Editing && c.Mode is { } m && m != Mode) continue;
            var p = CenterOf(c);
            var selected = c.Id == SelectedId;
            switch (c.Type)
            {
                case ControlType.Joystick:
                {
                    var rad = JoystickRadius(c);
                    dc.DrawEllipse(new SolidColorBrush(Color.FromArgb((byte)(Editing ? 30 : 13), 255, 255, 255)),
                        new Pen(new SolidColorBrush(Color.FromArgb((byte)(Editing ? 153 : 77), 255, 255, 255)), selected ? 3 : 1.5), p, rad, rad);
                    if (c.Keys is { Count: 4 } dirs)
                    {
                        Point[] spots = [new(p.X, p.Y - rad), new(p.X - rad, p.Y), new(p.X, p.Y + rad), new(p.X + rad, p.Y)];
                        for (int i = 0; i < 4; i++) Glyph.Draw(dc, dirs[i], spots[i], dim: dim);
                    }
                    if (c.BoostKey is { } boost)
                    {
                        var spot = new Point(p.X + rad * 0.75, p.Y - rad * 0.95);
                        Glyph.Draw(dc, boost, spot, 0.85, dim: dim);
                        if (Editing) Glyph.Caption(dc, "Sprint", spot, 14);
                    }
                    break;
                }
                case ControlType.Aim:
                    // crosshair
                    dc.DrawEllipse(null, new Pen(white, 2), new Point(p.X, p.Y - 6), 9, 9);
                    dc.DrawLine(new Pen(white, 2), new Point(p.X - 13, p.Y - 6), new Point(p.X + 13, p.Y - 6));
                    dc.DrawLine(new Pen(white, 2), new Point(p.X, p.Y - 19), new Point(p.X, p.Y + 7));
                    if (c.Key is { } ak) Glyph.Draw(dc, ak, new Point(p.X, p.Y + 18), dim: dim);
                    break;
                case ControlType.Look:
                    // eye
                    var eye = new PathGeometry();
                    var fig = new PathFigure { StartPoint = new Point(p.X - 13, p.Y - 6), IsClosed = true };
                    fig.Segments.Add(new QuadraticBezierSegment(new Point(p.X, p.Y - 18), new Point(p.X + 13, p.Y - 6), true));
                    fig.Segments.Add(new QuadraticBezierSegment(new Point(p.X, p.Y + 6), new Point(p.X - 13, p.Y - 6), true));
                    eye.Figures.Add(fig);
                    dc.DrawGeometry(null, new Pen(white, 2), eye);
                    dc.DrawEllipse(white, null, new Point(p.X, p.Y - 6), 3.5, 3.5);
                    if (c.Key is { } lk) Glyph.Draw(dc, lk, new Point(p.X, p.Y + 16), dim: dim);
                    break;
                default:
                    if (c.Key is { } k) Glyph.Draw(dc, k, p, highlighted: selected, dim: dim);
                    else Glyph.DrawKeycap(dc, "?", new Rect(p.X - 11, p.Y - 11, 22, 22), 1, selected, 0.9);
                    break;
            }
            if (Editing)
            {
                if (selected && c.Type != ControlType.Joystick)
                    dc.DrawEllipse(null, new Pen(Glyph.Accent, 2), p, 24, 24);
                if (c.Mode is { } cm)
                {
                    var off = c.Type == ControlType.Joystick ? JoystickRadius(c) * 0.7 : 16;
                    var badge = new Rect(p.X + off - 9, p.Y - off - 7, 18, 14);
                    dc.DrawRoundedRectangle(cm == ControlMode.Vehicle ? Glyph.Accent : new SolidColorBrush(Color.FromRgb(0x3C, 0x9A, 0x5F)), null, badge, 4, 4);
                    var t = new FormattedText(cm == ControlMode.Vehicle ? "car" : "foot", System.Globalization.CultureInfo.CurrentUICulture,
                        FlowDirection.LeftToRight, new Typeface("Segoe UI"), 8, Brushes.White, 1.0);
                    dc.DrawText(t, new Point(badge.X + (badge.Width - t.Width) / 2, badge.Y + (badge.Height - t.Height) / 2));
                }
                var below = c.Type == ControlType.Joystick ? JoystickRadius(c) + 14 : c.Type is ControlType.Aim or ControlType.Look ? 32 : 16;
                Glyph.Caption(dc, c.Label ?? c.Type.Title(), p, below);
            }
        }
    }

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        if (!Editing) return;
        Focus();
        _owner.ClosePopup();
        var p = e.GetPosition(this);
        if (ControlAt(p) is { } c)
        {
            SelectedId = c.Id;
            _dragOffset = p - CenterOf(c);
            _dragMoved = false;
            CaptureMouse();
        }
        else
        {
            SelectedId = null;
            if (e.ClickCount == 2) _owner.AddTapAt(p);
        }
        InvalidateVisual();
        e.Handled = true;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        if (!Editing || _dragOffset is not { } off || SelectedId == null || e.LeftButton != MouseButtonState.Pressed) return;
        var c = Keymap.Controls.FirstOrDefault(x => x.Id == SelectedId);
        if (c == null) return;
        var p = e.GetPosition(this) - off;
        var r = R;
        c.X = Math.Clamp((p.X - r.X) / r.Width, 0, 1);
        c.Y = Math.Clamp((p.Y - r.Y) / r.Height, 0, 1);
        _dragMoved = true;
        InvalidateVisual();
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        if (!Editing) return;
        ReleaseMouseCapture();
        var wasDragging = _dragOffset != null;
        _dragOffset = null;
        if (_dragMoved) { _owner.RaiseChanged(); return; }
        if (wasDragging && Keymap.Controls.FirstOrDefault(x => x.Id == SelectedId) is { } c) _owner.ShowInspector(c);
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        if (!Editing) return;
        if ((e.Key is Key.Delete or Key.Back) && SelectedId != null) { _owner.Remove(SelectedId); e.Handled = true; }
        else if (e.Key == Key.Escape) { _owner.RaiseDone(); e.Handled = true; }
    }
}

/// Edits one control: name, keys, size / sensitivity, cursor options, remove.
sealed class ControlInspector : Border
{
    public event Action? Changed;
    public event Action? RemoveRequested;

    public ControlInspector(Control control)
    {
        Background = new SolidColorBrush(Color.FromArgb(0xF5, 0x26, 0x26, 0x26));
        BorderBrush = new SolidColorBrush(Color.FromRgb(0x44, 0x44, 0x44));
        BorderThickness = new Thickness(1);
        CornerRadius = new CornerRadius(8);
        Padding = new Thickness(12);
        var rows = new StackPanel { MinWidth = 260 };
        Child = rows;
        TextBlock Label(string s) => new() { Text = s, Foreground = Brushes.Gray, Width = 58, VerticalAlignment = VerticalAlignment.Center, TextAlignment = TextAlignment.Right, Margin = new Thickness(0, 0, 8, 0) };
        void Row(string label, UIElement field) =>
            rows.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 4, 0, 4), Children = { Label(label), field } });
        void Note(string text) =>
            rows.Children.Add(new TextBlock { Text = text, Foreground = Brushes.Gray, FontSize = 11, TextWrapping = TextWrapping.Wrap, MaxWidth = 250, Margin = new Thickness(0, 4, 0, 4) });
        void Commit() => Changed?.Invoke();

        rows.Children.Add(new TextBlock { Text = control.Type.Title(), Foreground = Brushes.White, FontWeight = FontWeights.Bold, FontSize = 13, Margin = new Thickness(0, 0, 0, 6) });
        var name = new TextBox { Text = control.Label ?? "", Width = 170 };
        name.TextChanged += (_, _) => { control.Label = name.Text.Length == 0 ? null : name.Text; Commit(); };
        Row("Name", name);

        Slider MakeSlider(double value, double min, double max, Action<double> set)
        {
            var s = new Slider { Minimum = min, Maximum = max, Value = value, Width = 170 };
            s.ValueChanged += (_, e) => { set(e.NewValue); Commit(); };
            return s;
        }

        switch (control.Type)
        {
            case ControlType.Joystick:
                string[] names = ["Up", "Left", "Down", "Right"];
                for (int i = 0; i < 4; i++)
                {
                    var idx = i;
                    Row(names[i], new KeyCaptureButton(control.Keys?[i], k => { control.Keys![idx] = k; Commit(); }));
                }
                Row("Sprint", new KeyCaptureButton(control.BoostKey, k => { control.BoostKey = k; Commit(); }));
                Row("Size", MakeSlider(control.Radius ?? 0.12, 0.05, 0.25, v => control.Radius = v));
                break;
            case ControlType.Aim:
            case ControlType.Look:
                Row(control.Type == ControlType.Aim ? "Toggle" : "Hold", new KeyCaptureButton(control.Key, k => { control.Key = k; Commit(); }));
                Row("Speed", MakeSlider(control.Sensitivity ?? 1, 0.2, 3, v => control.Sensitivity = v));
                break;
            default:
                Row("Key", new KeyCaptureButton(control.Key, k => { control.Key = k; Commit(); }));
                break;
        }

        if (control.Type != ControlType.Aim)
        {
            var works = new ComboBox { Width = 170, ItemsSource = new[] { "Always", "On foot", "In vehicle" },
                SelectedIndex = control.Mode == null ? 0 : control.Mode == ControlMode.Foot ? 1 : 2 };
            works.SelectionChanged += (_, _) => { control.Mode = works.SelectedIndex switch { 1 => ControlMode.Foot, 2 => ControlMode.Vehicle, _ => null }; Commit(); };
            Row("Works", works);
        }
        if (control.Type == ControlType.Tap)
        {
            var then = new ComboBox { Width = 170, ItemsSource = new[] { "Nothing else", "Switch to vehicle controls", "Switch to on-foot controls", "Toggle vehicle / on-foot" },
                SelectedIndex = control.SwitchesTo switch { ModeSwitch.Vehicle => 1, ModeSwitch.Foot => 2, ModeSwitch.Toggle => 3, _ => 0 } };
            then.SelectionChanged += (_, _) => { control.SwitchesTo = then.SelectedIndex switch { 1 => ModeSwitch.Vehicle, 2 => ModeSwitch.Foot, 3 => ModeSwitch.Toggle, _ => null }; Commit(); };
            Row("Then", then);
        }
        if (control.Type == ControlType.Tap)
        {
            CheckBox Check(string text, string tip, bool? value, Action<bool> set)
            {
                var cb = new CheckBox { Content = text, Foreground = Brushes.White, IsChecked = value == true, ToolTip = tip, Margin = new Thickness(0, 4, 0, 4) };
                cb.Click += (_, _) => { set(cb.IsChecked == true); Commit(); };
                return cb;
            }
            rows.Children.Add(Check("Show cursor (for bag, map, menus)",
                "During mouse aim, this button shows the cursor; pressing it again (or Esc) resumes aim",
                control.ShowsCursor, v => control.ShowsCursor = v ? true : null));
            rows.Children.Add(Check("Hold to keep open (closes on release)",
                "Pressing the key opens it; letting go taps it again to close",
                control.HoldToOpen, v => control.HoldToOpen = v ? true : null));
        }
        if (control.Type == ControlType.Aim) Note("Press it in game to lock the mouse for aiming. Esc releases it.");
        if (control.Type == ControlType.Fire) Note("Works while mouse aim is on.");

        var remove = KeymapOverlay.ToolButton("Remove");
        remove.Foreground = new SolidColorBrush(Color.FromRgb(0xFF, 0x6B, 0x6B));
        remove.HorizontalAlignment = HorizontalAlignment.Left;
        remove.Margin = new Thickness(0, 8, 0, 0);
        remove.Click += (_, _) => RemoveRequested?.Invoke();
        rows.Children.Add(remove);
    }
}

/// Shows a key as a keycap / mouse icon; click it, then press a key, click, or scroll
/// to rebind. Escape cancels.
sealed class KeyCaptureButton : Button
{
    InputKey? _key;
    readonly Action<InputKey> _changed;
    bool _capturing;

    public KeyCaptureButton(InputKey? key, Action<InputKey> changed)
    {
        _key = key;
        _changed = changed;
        MinWidth = 170;
        HorizontalContentAlignment = HorizontalAlignment.Left;
        Padding = new Thickness(6, 3, 6, 3);
        Refresh();
        Click += (_, _) =>
        {
            if (_capturing) return;
            _capturing = true;
            Refresh();
            Focus();
        };
        LostKeyboardFocus += (_, _) => { if (_capturing) { _capturing = false; Refresh(); } };
    }

    void Refresh()
    {
        if (_capturing) { Content = "Press a key, click or scroll…"; return; }
        if (_key is not { } k) { Content = "Choose a key"; return; }
        var group = new DrawingGroup();
        using (var dc = group.Open())
        {
            var sz = Glyph.SizeOf(k);
            dc.DrawRectangle(Brushes.Transparent, null, new Rect(0, 0, sz.Width + 12, sz.Height + 4));
            Glyph.Draw(dc, k, new Point(sz.Width / 2 + 2, sz.Height / 2 + 2));
        }
        Content = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Children =
            {
                new Image { Source = new DrawingImage(group), Stretch = Stretch.None, Margin = new Thickness(0, 0, 6, 0) },
                new TextBlock { Text = k.LongName, VerticalAlignment = VerticalAlignment.Center },
            },
        };
    }

    void Finish(InputKey? k)
    {
        _capturing = false;
        if (k is { } key) { _key = key; _changed(key); }
        Refresh();
    }

    protected override void OnPreviewKeyDown(KeyEventArgs e)
    {
        if (!_capturing) { base.OnPreviewKeyDown(e); return; }
        e.Handled = true;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (key == Key.Escape) { Finish(null); return; }
        if (InputKey.FromWpf(key) is { } mac) Finish(InputKey.KeyCode(mac));
    }

    protected override void OnPreviewMouseDown(MouseButtonEventArgs e)
    {
        if (!_capturing) { base.OnPreviewMouseDown(e); return; }
        e.Handled = true;
        var n = e.ChangedButton switch
        {
            MouseButton.Left => 0, MouseButton.Right => 1, MouseButton.Middle => 2, MouseButton.XButton1 => 3, _ => 4,
        };
        Finish(InputKey.Mouse(n));
    }

    protected override void OnPreviewMouseWheel(MouseWheelEventArgs e)
    {
        if (!_capturing) { base.OnPreviewMouseWheel(e); return; }
        e.Handled = true;
        Finish(e.Delta > 0 ? InputKey.ScrollUp : InputKey.ScrollDown);
    }
}
