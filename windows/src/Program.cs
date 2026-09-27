using System.IO;
using System.Windows;

namespace Pocketbay;

public static class Program
{
    [STAThread]
    public static void Main()
    {
        // The emulator's gRPC endpoint is plain HTTP/2 on localhost.
        AppContext.SetSwitch("System.Net.Http.SocketsHttpHandler.Http2UnencryptedSupport", true);
        if (Updater.ApplyPendingUpdate()) return;
        var app = new Application { ShutdownMode = ShutdownMode.OnMainWindowClose };
        app.DispatcherUnhandledException += (_, e) =>
        {
            Log.Write("Unhandled: " + e.Exception);
            MessageBox.Show(e.Exception.Message, "Pocketbay", MessageBoxButton.OK, MessageBoxImage.Error);
            e.Handled = true;
        };
        app.Run(new MainWindow());
    }
}

/// Where Pocketbay keeps its files.
public static class Paths
{
    public static string Local => Dir(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Pocketbay");
    public static string Sdk => Dir(Local, "sdk");
    public static string AvdHome => Dir(Local, "avd");
    public static string Logs => Dir(Local, "logs");
    public static string Downloads => Dir(Local, "downloads");
    public static string Roaming => Dir(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Pocketbay");
    public static string Layouts => Dir(Roaming, "Layouts");
    public static string Settings => Path.Combine(Roaming, "settings.json");

    public static string Adb => Path.Combine(Sdk, "platform-tools", "adb.exe");
    public static string Emulator => Path.Combine(Sdk, "emulator", "emulator.exe");

    static string Dir(params string[] parts)
    {
        var p = Path.Combine(parts);
        Directory.CreateDirectory(p);
        return p;
    }
}

public static class Log
{
    static readonly object Gate = new();
    public static void Write(string line)
    {
        try
        {
            lock (Gate) File.AppendAllText(Path.Combine(Paths.Logs, "pocketbay.log"), $"{DateTime.Now:HH:mm:ss.fff} {line}{Environment.NewLine}");
        }
        catch { }
    }
}
