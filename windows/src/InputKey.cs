using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows.Input;

namespace Pocketbay;

/// A physical input that drives a mapped control. Keys are stored as Mac virtual key
/// codes so layout files are identical between the Mac and Windows versions.
[JsonConverter(typeof(InputKeyConverter))]
public readonly record struct InputKey(InputKind Kind, int Code)
{
    public static InputKey KeyCode(int mac) => new(InputKind.Key, mac);
    public static InputKey Mouse(int button) => new(InputKind.Mouse, button);
    public static readonly InputKey ScrollUp = new(InputKind.ScrollUp, 0);
    public static readonly InputKey ScrollDown = new(InputKind.ScrollDown, 0);

    public bool IsMouse => Kind != InputKind.Key;

    /// Short keycap text ("W", "⇧", "Space"); null for mouse inputs (drawn as a mouse).
    public string? CapLabel => Kind == InputKind.Key ? (Names.TryGetValue(Code, out var n) ? n : $"#{Code}") : null;

    public string LongName => Kind switch
    {
        InputKind.Key => LongNames.TryGetValue(Code, out var n) ? n : CapLabel ?? "Key",
        InputKind.Mouse => Code switch { 0 => "Left click", 1 => "Right click", 2 => "Middle click", _ => $"Mouse button {Code + 1}" },
        InputKind.ScrollUp => "Scroll up",
        _ => "Scroll down",
    };

    public override string ToString() => Kind switch
    {
        InputKind.Key => $"k:{Code}",
        InputKind.Mouse => $"m:{Code}",
        InputKind.ScrollUp => "wheel:up",
        _ => "wheel:down",
    };

    public static InputKey? Parse(string s)
    {
        if (s == "wheel:up") return ScrollUp;
        if (s == "wheel:down") return ScrollDown;
        var parts = s.Split(':');
        if (parts.Length != 2 || !int.TryParse(parts[1], out var n)) return null;
        return parts[0] == "m" ? Mouse(n) : KeyCode(n);
    }

    // Mac virtual key codes (kVK_*) → keycap text. Same table as the Mac app.
    static readonly Dictionary<int, string> Names = new()
    {
        [0] = "A", [11] = "B", [8] = "C", [2] = "D", [14] = "E", [3] = "F", [5] = "G", [4] = "H", [34] = "I",
        [38] = "J", [40] = "K", [37] = "L", [46] = "M", [45] = "N", [31] = "O", [35] = "P", [12] = "Q", [15] = "R",
        [1] = "S", [17] = "T", [32] = "U", [9] = "V", [13] = "W", [7] = "X", [16] = "Y", [6] = "Z",
        [29] = "0", [18] = "1", [19] = "2", [20] = "3", [21] = "4", [23] = "5", [22] = "6", [26] = "7", [28] = "8", [25] = "9",
        [50] = "`", [27] = "-", [24] = "=", [33] = "[", [30] = "]", [42] = "\\", [41] = ";", [39] = "'", [43] = ",",
        [47] = ".", [44] = "/",
        [49] = "Space", [48] = "Tab", [36] = "Enter", [51] = "Bksp", [53] = "Esc", [117] = "Del",
        [56] = "Shift", [60] = "RShift", [59] = "Ctrl", [62] = "RCtrl", [58] = "Alt", [61] = "RAlt", [57] = "Caps",
        [123] = "←", [124] = "→", [125] = "↓", [126] = "↑",
        [115] = "Home", [119] = "End", [116] = "PgUp", [121] = "PgDn",
        [122] = "F1", [120] = "F2", [99] = "F3", [118] = "F4", [96] = "F5", [97] = "F6",
        [98] = "F7", [100] = "F8", [101] = "F9", [109] = "F10", [103] = "F11", [111] = "F12",
    };

    static readonly Dictionary<int, string> LongNames = new()
    {
        [49] = "Space", [48] = "Tab", [36] = "Enter", [51] = "Backspace", [53] = "Escape", [56] = "Shift", [60] = "Right Shift",
        [59] = "Ctrl", [62] = "Right Ctrl", [58] = "Alt", [61] = "Right Alt", [57] = "Caps Lock", [50] = "Backtick (`)",
        [123] = "Left arrow", [124] = "Right arrow", [125] = "Down arrow", [126] = "Up arrow",
    };

    /// Windows key → Mac virtual key code (what layouts and the emulator use).
    public static int? FromWpf(Key key) => WpfToMac.TryGetValue(key, out var mac) ? mac : null;

    static readonly Dictionary<Key, int> WpfToMac = new()
    {
        [Key.A] = 0, [Key.B] = 11, [Key.C] = 8, [Key.D] = 2, [Key.E] = 14, [Key.F] = 3, [Key.G] = 5, [Key.H] = 4, [Key.I] = 34,
        [Key.J] = 38, [Key.K] = 40, [Key.L] = 37, [Key.M] = 46, [Key.N] = 45, [Key.O] = 31, [Key.P] = 35, [Key.Q] = 12, [Key.R] = 15,
        [Key.S] = 1, [Key.T] = 17, [Key.U] = 32, [Key.V] = 9, [Key.W] = 13, [Key.X] = 7, [Key.Y] = 16, [Key.Z] = 6,
        [Key.D0] = 29, [Key.D1] = 18, [Key.D2] = 19, [Key.D3] = 20, [Key.D4] = 21, [Key.D5] = 23, [Key.D6] = 22, [Key.D7] = 26, [Key.D8] = 28, [Key.D9] = 25,
        [Key.NumPad0] = 29, [Key.NumPad1] = 18, [Key.NumPad2] = 19, [Key.NumPad3] = 20, [Key.NumPad4] = 21,
        [Key.NumPad5] = 23, [Key.NumPad6] = 22, [Key.NumPad7] = 26, [Key.NumPad8] = 28, [Key.NumPad9] = 25,
        [Key.OemTilde] = 50, [Key.OemMinus] = 27, [Key.OemPlus] = 24, [Key.OemOpenBrackets] = 33, [Key.Oem6] = 30,
        [Key.Oem5] = 42, [Key.Oem1] = 41, [Key.OemQuotes] = 39, [Key.OemComma] = 43, [Key.OemPeriod] = 47, [Key.OemQuestion] = 44,
        [Key.Space] = 49, [Key.Tab] = 48, [Key.Enter] = 36, [Key.Back] = 51, [Key.Escape] = 53, [Key.Delete] = 117,
        [Key.LeftShift] = 56, [Key.RightShift] = 60, [Key.LeftCtrl] = 59, [Key.RightCtrl] = 62,
        [Key.LeftAlt] = 58, [Key.RightAlt] = 61, [Key.CapsLock] = 57,
        [Key.Left] = 123, [Key.Right] = 124, [Key.Down] = 125, [Key.Up] = 126,
        [Key.Home] = 115, [Key.End] = 119, [Key.PageUp] = 116, [Key.PageDown] = 121,
        [Key.F1] = 122, [Key.F2] = 120, [Key.F3] = 99, [Key.F4] = 118, [Key.F5] = 96, [Key.F6] = 97,
        [Key.F7] = 98, [Key.F8] = 100, [Key.F9] = 101, [Key.F10] = 109, [Key.F11] = 103, [Key.F12] = 111,
    };
}

public enum InputKind { Key, Mouse, ScrollUp, ScrollDown }

public sealed class InputKeyConverter : JsonConverter<InputKey>
{
    public override InputKey Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        InputKey.Parse(reader.GetString() ?? "") ?? throw new JsonException("Bad key");

    public override void Write(Utf8JsonWriter writer, InputKey value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.ToString());
}
