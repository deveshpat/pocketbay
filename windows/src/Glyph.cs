using System.Globalization;
using System.Windows;
using System.Windows.Media;

namespace Pocketbay;

/// Keycaps and mouse icons for key hints and the controls editor.
public static class Glyph
{
    static readonly Typeface Face = new(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal);
    public static readonly Brush Accent = new SolidColorBrush(Color.FromRgb(0x2F, 0x81, 0xF7));

    static FormattedText Text(string s, double size, Brush brush, double dpi = 1.0) =>
        new(s, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, Face, size, brush, dpi);

    public static Size SizeOf(InputKey key, double scale = 1)
    {
        if (key.CapLabel is { } label)
        {
            var w = Text(label, 12, Brushes.White).Width;
            return new Size(Math.Max(22, w + 12) * scale, 22 * scale);
        }
        return new Size(18 * scale, 24 * scale);
    }

    public static void Draw(DrawingContext dc, InputKey key, Point center, double scale = 1, bool highlighted = false, bool dim = false)
    {
        var sz = SizeOf(key, scale);
        var rect = new Rect(center.X - sz.Width / 2, center.Y - sz.Height / 2, sz.Width, sz.Height);
        var alpha = dim ? 0.55 : 0.95;
        if (key.CapLabel is { } label) DrawKeycap(dc, label, rect, scale, highlighted, alpha);
        else DrawMouse(dc, key, rect, highlighted, alpha);
    }

    static Brush White(double a) => new SolidColorBrush(Color.FromArgb((byte)(a * 255), 255, 255, 255));
    static Brush Dark(double a) => new SolidColorBrush(Color.FromArgb((byte)(a * 255), 36, 36, 36));

    public static void DrawKeycap(DrawingContext dc, string label, Rect rect, double scale, bool highlighted, double alpha)
    {
        var r = 5 * scale;
        dc.DrawRoundedRectangle(new SolidColorBrush(Color.FromArgb((byte)(0.45 * alpha * 255), 0, 0, 0)), null,
            new Rect(rect.X, rect.Y + 1.5 * scale, rect.Width, rect.Height), r, r);
        dc.DrawRoundedRectangle(highlighted ? Accent : Dark(0.88 * alpha), new Pen(White(0.35 * alpha), 1), rect, r, r);
        var t = Text(label, 12 * scale, White(alpha));
        dc.DrawText(t, new Point(rect.X + (rect.Width - t.Width) / 2, rect.Y + (rect.Height - t.Height) / 2));
    }

    /// A mouse outline with the relevant button (or wheel) filled in.
    public static void DrawMouse(DrawingContext dc, InputKey key, Rect rect, bool highlighted, double alpha)
    {
        var radius = rect.Width / 2;
        var body = new RectangleGeometry(rect, radius, radius);
        dc.DrawGeometry(Dark(0.88 * alpha), null, body);
        var fill = highlighted ? Accent : White(0.9 * alpha);
        var top = rect.Height * 0.45;
        var buttons = new Rect(rect.X, rect.Y, rect.Width, top);

        dc.PushClip(body);
        if (key.Kind == InputKind.Mouse && key.Code == 0) dc.DrawRectangle(fill, null, new Rect(buttons.X, buttons.Y, buttons.Width / 2 - 0.5, buttons.Height));
        if (key.Kind == InputKind.Mouse && key.Code == 1) dc.DrawRectangle(fill, null, new Rect(buttons.X + buttons.Width / 2 + 0.5, buttons.Y, buttons.Width / 2, buttons.Height));
        dc.Pop();

        var pen = new Pen(White(0.6 * alpha), 1);
        dc.DrawLine(pen, new Point(buttons.X + buttons.Width / 2, buttons.Top), new Point(buttons.X + buttons.Width / 2, buttons.Bottom));
        dc.DrawLine(pen, new Point(rect.Left, buttons.Bottom), new Point(rect.Right, buttons.Bottom));
        dc.DrawGeometry(null, pen, body);

        var wheelActive = key.Kind is InputKind.ScrollUp or InputKind.ScrollDown || (key.Kind == InputKind.Mouse && key.Code == 2);
        dc.DrawRoundedRectangle(wheelActive ? fill : Dark(alpha), null,
            new Rect(rect.X + rect.Width / 2 - 1.5, buttons.Y + buttons.Height / 2 - 3.5, 3, 7), 1.5, 1.5);
        if (key.Kind == InputKind.Mouse && key.Code >= 3)
            dc.DrawText(Text((key.Code + 1).ToString(), 8, fill), new Point(rect.X + rect.Width / 2 - 3, rect.Y + rect.Height / 2));
        if (key.Kind is InputKind.ScrollUp or InputKind.ScrollDown)
        {
            var up = key.Kind == InputKind.ScrollUp;
            double ax = rect.Right + 5, ay = rect.Y + rect.Height / 2;
            var arrowPen = new Pen(fill, 1.5);
            dc.DrawLine(arrowPen, new Point(ax - 3, up ? ay + 2 : ay - 2), new Point(ax, up ? ay - 2 : ay + 2));
            dc.DrawLine(arrowPen, new Point(ax, up ? ay - 2 : ay + 2), new Point(ax + 3, up ? ay + 2 : ay - 2));
        }
    }

    /// Segoe MDL2 / Fluent icon glyph (present on Windows 10 and 11).
    public static void DrawIcon(DrawingContext dc, string glyph, Point center, double size, double alpha = 0.95)
    {
        var t = new FormattedText(glyph, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight,
            new Typeface(new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"), FontStyles.Normal, FontWeights.Normal, FontStretches.Normal),
            size, White(alpha), 1.0);
        dc.DrawText(t, new Point(center.X - t.Width / 2, center.Y - t.Height / 2));
    }

    public static void Caption(DrawingContext dc, string text, Point below, double offset)
    {
        var t = Text(text, 11, Brushes.White);
        var p = new Point(below.X - t.Width / 2, below.Y + offset - 2);
        var shadow = Text(text, 11, Brushes.Black);
        dc.DrawText(shadow, new Point(p.X + 1, p.Y + 1));
        dc.DrawText(t, p);
    }
}
