using System.IO;
using System.IO.Compression;
using System.Text.Json;

namespace Pocketbay;

/// Installs a game pack: a zip with pack.json, the app's APK(s), its OBB and its
/// downloaded game data, so a big game doesn't have to download again.
public static class GamePack
{
    sealed record Manifest(string Package, string Name, List<string> Apks, string? Obb, string? Data);

    public static bool LooksLikePack(string path)
    {
        if (!File.Exists(path)) return false;
        try { using var z = ZipFile.OpenRead(path); return z.GetEntry("pack.json") != null; } catch { return false; }
    }

    public static async Task<string> InstallAsync(string packPath, EmulatorManager manager, IProgress<string> progress)
    {
        var opts = new JsonSerializerOptions { PropertyNameCaseInsensitive = true };
        Manifest manifest;
        using (var z = ZipFile.OpenRead(packPath))
        {
            using var s = z.GetEntry("pack.json")!.Open();
            manifest = JsonSerializer.Deserialize<Manifest>(s, opts) ?? throw new InvalidDataException("Bad pack.json");
        }
        var pkg = manifest.Package;
        var name = manifest.Name ?? pkg;

        var need = new FileInfo(packPath).Length + (2L << 30);
        if (SdkInstaller.FreeBytes() < need)
            throw new IOException($"Not enough free disk space: need about {need >> 30} GB.");

        var tmp = Path.Combine(Paths.Local, "pack-tmp");
        if (Directory.Exists(tmp)) Directory.Delete(tmp, true);
        try
        {
            progress.Report($"Unpacking {name}… (a few minutes)");
            await Task.Run(() => ZipFile.ExtractToDirectory(packPath, tmp));

            progress.Report($"Installing {name}…");
            var apks = manifest.Apks.Select(a => Path.Combine(tmp, "apks", a)).ToArray();
            var (code, output) = apks.Length == 1
                ? await manager.RunAdbLong(["install", "-r", apks[0]])
                : await manager.RunAdbLong(["install-multiple", "-r", .. apks]);
            if (code != 0 || !output.Contains("Success"))
                throw new InvalidOperationException("Install failed: " + output.Trim().Split('\n').Last());

            // Let the game create its own folders so Android gives them the right owner.
            progress.Report($"Preparing {name}…");
            await manager.RunAdb("shell", $"monkey -p {pkg} -c android.intent.category.LAUNCHER 1");
            for (int i = 0; i < 90; i++)
            {
                var (c, _) = await manager.RunAdb("shell", $"ls /sdcard/Android/data/{pkg}/files");
                if (c == 0) break;
                await Task.Delay(1000);
            }
            await Task.Delay(3000);
            await manager.RunAdb("shell", $"am force-stop {pkg}");

            if (manifest.Obb is { } obb && Directory.Exists(Path.Combine(tmp, obb)))
            {
                progress.Report($"Copying {name} game files (1/2)…");
                await manager.RunAdb("shell", $"mkdir -p /sdcard/Android/obb/{pkg}");
                await manager.RunAdbLong(["push", Path.Combine(tmp, obb) + Path.DirectorySeparatorChar + ".", $"/sdcard/Android/obb/{pkg}/"]);
                await manager.RunAdb("shell", $"chmod -R a+rwX /sdcard/Android/obb/{pkg}");
            }
            if (manifest.Data is { } data && Directory.Exists(Path.Combine(tmp, data)))
            {
                progress.Report($"Copying {name} game files (2/2)… (several minutes)");
                await manager.RunAdbLong(["push", Path.Combine(tmp, data) + Path.DirectorySeparatorChar + ".", $"/sdcard/Android/data/{pkg}/"]);
                // Pushed folders arrive owner-only; make them readable by the game.
                await manager.RunAdb("shell", $"chmod -R a+rwX /sdcard/Android/data/{pkg}/files");
            }
            return $"{name} installed — open it from the home screen";
        }
        finally
        {
            try { Directory.Delete(tmp, true); } catch { }
        }
    }
}
