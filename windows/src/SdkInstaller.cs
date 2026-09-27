using System.IO;
using System.IO.Compression;
using System.Net.Http;
using System.Security.Cryptography;
using System.Xml.Linq;

namespace Pocketbay;

/// Downloads the Android emulator, platform-tools and the Play Store system image straight
/// from Google (no Android Studio or Java needed) and creates the Pocketbay AVD.
public static class SdkInstaller
{
    const string Repo = "https://dl.google.com/android/repository/";
    const string SysImgRepo = Repo + "sys-img/google_apis_playstore/";
    const string SysImgPath = "system-images;android-35;google_apis_playstore;x86_64";
    const string Abi = "x86_64";

    public static string SystemImageDir => Path.Combine(Paths.Sdk, "system-images", "android-35", "google_apis_playstore", Abi);
    static string AvdDir => Path.Combine(Paths.AvdHome, EmulatorManager.AvdName + ".avd");
    static string AvdIni => Path.Combine(Paths.AvdHome, EmulatorManager.AvdName + ".ini");

    public static bool IsInstalled =>
        File.Exists(Paths.Emulator) && File.Exists(Paths.Adb) &&
        File.Exists(Path.Combine(SystemImageDir, "system.img")) && File.Exists(Path.Combine(AvdDir, "config.ini"));

    public sealed record Package(string Name, string Url, long Size, string? Sha1, string ZipRoot, string Target);

    static readonly HttpClient Http = new() { Timeout = TimeSpan.FromHours(2) };

    /// Google's Android SDK license text, from the same repository the packages come from.
    public static async Task<string> FetchLicenseAsync()
    {
        var xml = XDocument.Parse(await Http.GetStringAsync(Repo + "repository2-3.xml"));
        var lic = xml.Descendants().FirstOrDefault(e => e.Name.LocalName == "license" && (string?)e.Attribute("id") == "android-sdk-license");
        return lic?.Value.Trim() ?? "See https://developer.android.com/studio/terms";
    }

    /// Stable (channel-0) Windows packages.
    public static async Task<List<Package>> ResolvePackagesAsync()
    {
        var repo = XDocument.Parse(await Http.GetStringAsync(Repo + "repository2-3.xml"));
        var sys = XDocument.Parse(await Http.GetStringAsync(SysImgRepo + "sys-img2-3.xml"));

        Package Pick(XDocument doc, string path, string baseUrl, string zipRoot, string target, string? hostOs)
        {
            var pkg = doc.Descendants().Where(e => e.Name.LocalName == "remotePackage" && (string?)e.Attribute("path") == path)
                .OrderBy(e => (string?)e.Elements().FirstOrDefault(c => c.Name.LocalName == "channelRef")?.Attribute("ref") == "channel-0" ? 0 : 1)
                .First();
            var archive = pkg.Descendants().Where(e => e.Name.LocalName == "archive").First(a =>
                hostOs == null || a.Elements().Any(c => c.Name.LocalName == "host-os" && c.Value == hostOs));
            var complete = archive.Elements().First(e => e.Name.LocalName == "complete");
            string Get(string n) => complete.Elements().First(e => e.Name.LocalName == n).Value;
            var sha = complete.Elements().FirstOrDefault(e => e.Name.LocalName == "checksum")?.Value;
            return new Package(path, baseUrl + Get("url"), long.Parse(Get("size")), sha, zipRoot, target);
        }

        return
        [
            Pick(repo, "platform-tools", Repo, "platform-tools", Path.Combine(Paths.Sdk, "platform-tools"), "windows"),
            Pick(repo, "emulator", Repo, "emulator", Path.Combine(Paths.Sdk, "emulator"), "windows"),
            Pick(sys, SysImgPath, SysImgRepo, Abi, SystemImageDir, null),
        ];
    }

    /// Downloads, verifies and unpacks everything, then creates the AVD.
    /// `progress` reports (message, fraction 0…1).
    public static async Task InstallAsync(IProgress<(string, double)> progress, CancellationToken ct)
    {
        progress.Report(("Finding the latest Android packages…", 0));
        var packages = await ResolvePackagesAsync();
        long total = packages.Sum(p => p.Size), done = 0;

        foreach (var pkg in packages)
        {
            if (IsPresent(pkg)) { done += pkg.Size; continue; }
            var zip = Path.Combine(Paths.Downloads, Path.GetFileName(new Uri(pkg.Url).LocalPath));
            await DownloadAsync(pkg, zip, b => progress.Report(($"Downloading {Friendly(pkg.Name)}…", (done + b) / (double)total)), ct);
            done += pkg.Size;
            progress.Report(($"Unpacking {Friendly(pkg.Name)}…", done / (double)total));
            await Task.Run(() => Extract(zip, pkg), ct);
            try { File.Delete(zip); } catch { }
        }
        progress.Report(("Creating the Android device…", 1));
        CreateAvd();
    }

    static string Friendly(string name) => name switch
    {
        "platform-tools" => "Android tools",
        "emulator" => "the Android emulator",
        _ => "Android 15 (Play Store)",
    };

    static bool IsPresent(Package p) => p.ZipRoot switch
    {
        "platform-tools" => File.Exists(Paths.Adb),
        "emulator" => File.Exists(Paths.Emulator),
        _ => File.Exists(Path.Combine(SystemImageDir, "system.img")),
    };

    static async Task DownloadAsync(Package pkg, string dest, Action<long> onBytes, CancellationToken ct)
    {
        // Resume a partial download if one is there.
        long existing = File.Exists(dest) ? new FileInfo(dest).Length : 0;
        if (existing > pkg.Size) { File.Delete(dest); existing = 0; }
        if (existing < pkg.Size)
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, pkg.Url);
            if (existing > 0) req.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(existing, null);
            using var resp = await Http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);
            resp.EnsureSuccessStatusCode();
            if (existing > 0 && resp.StatusCode != System.Net.HttpStatusCode.PartialContent) existing = 0;
            await using var input = await resp.Content.ReadAsStreamAsync(ct);
            await using var output = new FileStream(dest, existing > 0 ? FileMode.Append : FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20);
            var buffer = new byte[1 << 20];
            long got = existing;
            int n;
            var lastReport = DateTime.MinValue;
            while ((n = await input.ReadAsync(buffer, ct)) > 0)
            {
                await output.WriteAsync(buffer.AsMemory(0, n), ct);
                got += n;
                if ((DateTime.Now - lastReport).TotalMilliseconds > 200) { onBytes(got); lastReport = DateTime.Now; }
            }
        }
        if (pkg.Sha1 != null)
        {
            await using var fs = File.OpenRead(dest);
            var hash = Convert.ToHexString(await SHA1.HashDataAsync(fs, ct)).ToLowerInvariant();
            if (hash != pkg.Sha1.ToLowerInvariant())
            {
                File.Delete(dest);
                throw new InvalidDataException($"The download of {Friendly(pkg.Name)} was corrupted. Please try again.");
            }
        }
    }

    static void Extract(string zip, Package pkg)
    {
        var tmp = Path.Combine(Paths.Downloads, "unpack-" + pkg.ZipRoot);
        if (Directory.Exists(tmp)) Directory.Delete(tmp, true);
        ZipFile.ExtractToDirectory(zip, tmp);
        var root = Path.Combine(tmp, pkg.ZipRoot);
        if (!Directory.Exists(root)) root = tmp;
        if (Directory.Exists(pkg.Target)) Directory.Delete(pkg.Target, true);
        Directory.CreateDirectory(Path.GetDirectoryName(pkg.Target)!);
        Directory.Move(root, pkg.Target);
        if (Directory.Exists(tmp)) Directory.Delete(tmp, true);
    }

    /// Writes the AVD files directly (what avdmanager would create).
    public static void CreateAvd()
    {
        Directory.CreateDirectory(AvdDir);
        File.WriteAllText(AvdIni, $"avd.ini.encoding=UTF-8\npath={AvdDir}\npath.rel=avd{Path.DirectorySeparatorChar}{EmulatorManager.AvdName}.avd\ntarget=android-35\n");

        var ramGb = GC.GetGCMemoryInfo().TotalAvailableMemoryBytes / (1024.0 * 1024 * 1024);
        int ramMb = ramGb >= 15 ? 6144 : ramGb >= 11 ? 4096 : 3072;
        int cores = Math.Clamp(Environment.ProcessorCount / 2, 2, 6);
        var config = new Dictionary<string, string>
        {
            ["avd.ini.encoding"] = "UTF-8",
            ["AvdId"] = EmulatorManager.AvdName,
            ["avd.ini.displayname"] = EmulatorManager.AvdName,
            ["PlayStore.enabled"] = "yes",
            ["abi.type"] = Abi,
            ["hw.cpu.arch"] = "x86_64",
            ["image.sysdir.1"] = $"system-images{Path.DirectorySeparatorChar}android-35{Path.DirectorySeparatorChar}google_apis_playstore{Path.DirectorySeparatorChar}{Abi}{Path.DirectorySeparatorChar}",
            ["tag.id"] = "google_apis_playstore",
            ["tag.display"] = "Google Play",
            ["target"] = "android-35",
            ["hw.lcd.width"] = "1920",
            ["hw.lcd.height"] = "1080",
            ["hw.lcd.density"] = "240",
            ["hw.lcd.vsync"] = "60",
            ["hw.initialOrientation"] = "landscape",
            ["showDeviceFrame"] = "no",
            ["skin.dynamic"] = "yes",
            ["hw.ramSize"] = ramMb.ToString(),
            ["vm.heapSize"] = "512",
            ["hw.cpu.ncore"] = cores.ToString(),
            ["disk.dataPartition.size"] = "16G",
            ["sdcard.size"] = "512M",
            ["hw.sdCard"] = "yes",
            ["hw.gpu.enabled"] = "yes",
            ["hw.gpu.mode"] = "host",
            ["hw.keyboard"] = "yes",
            ["hw.mainKeys"] = "no",
            ["hw.audioOutput"] = "yes",
            ["hw.audioInput"] = "yes",
            ["hw.accelerometer"] = "yes",
            ["hw.gyroscope"] = "yes",
            ["hw.sensors.orientation"] = "yes",
            ["fastboot.forceColdBoot"] = "no",
            ["fastboot.forceFastBoot"] = "yes",
        };
        File.WriteAllText(Path.Combine(AvdDir, "config.ini"), string.Join("\n", config.Select(kv => $"{kv.Key}={kv.Value}")) + "\n");
    }

    /// Asks the emulator whether hardware virtualization (WHPX / AEHD) is usable.
    public static async Task<(bool Ok, string Detail)> CheckAccelerationAsync()
    {
        var (code, output) = await EmulatorManager.Run(Paths.Emulator, ["-accel-check"], 60_000);
        var ok = code == 0 && output.Contains("is installed and usable");
        return (ok, output.Trim());
    }

    public static long FreeBytes()
    {
        try { return new DriveInfo(Path.GetPathRoot(Paths.Local)!).AvailableFreeSpace; } catch { return long.MaxValue; }
    }
}
