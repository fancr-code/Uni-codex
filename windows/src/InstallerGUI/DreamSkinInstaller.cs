using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Text.Json;

namespace CodexOneClickInstaller;

internal static class DreamSkinInstaller
{
    public const string GothicPreset = "preset-gothic-void-crusade";
    public const string GalleryPreset = "gallery";
    public const string NonePreset = "none";
    private const string GalleryUrl = "https://dreamskin.cc/gallery";
    private const string GalleryApiUrl =
        "https://api.dreamskin.cc/v1/themes?sort=popular&limit=24";
    private static readonly HttpClient GalleryApiClient = CreateGalleryApiClient();

    private static HttpClient CreateGalleryApiClient()
    {
        var client = new HttpClient
        {
            Timeout = TimeSpan.FromSeconds(20)
        };
        client.DefaultRequestHeaders.UserAgent.ParseAdd(
            "Uni-codex DreamSkin gallery connector");
        client.DefaultRequestHeaders.Accept.ParseAdd("application/json");
        return client;
    }

    public static async Task InstallAsync(
        string? setupPath,
        string preset,
        IProgress<InstallerEvent> progress,
        CancellationToken cancellationToken)
    {
        if (string.Equals(preset, NonePreset, StringComparison.Ordinal))
        {
            progress.Report(new InstallerEvent(
                "dream_skin_skipped", 0.94, "保留官方默认外观", null));
            return;
        }
        var openGallery = string.Equals(preset, GalleryPreset, StringComparison.Ordinal);
        if (!string.Equals(preset, GothicPreset, StringComparison.Ordinal) && !openGallery)
            throw new InvalidOperationException("不支持的 Dream Skin 预设。");
        if (string.IsNullOrWhiteSpace(setupPath) ||
            !File.Exists(setupPath))
            throw new FileNotFoundException("安装包未包含 Codex Dream Skin 安装程序。", setupPath);

        progress.Report(new InstallerEvent(
            "dream_skin_installing", 0.91,
            openGallery
                ? "正在安装 Codex Dream Skin，并准备 10 套精选主题"
                : "正在安装 Codex Dream Skin（Gothic Void Crusade）",
            null));
        using var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = Path.GetFullPath(setupPath),
                Arguments = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-",
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = Path.GetDirectoryName(Path.GetFullPath(setupPath))!
            }
        };
        if (!process.Start())
            throw new InvalidOperationException("无法启动 Codex Dream Skin 安装程序。");
        try
        {
            await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
            catch { /* cancellation/failure path */ }
            throw;
        }
        if (process.ExitCode != 0)
            throw new InvalidOperationException(
                $"Codex Dream Skin 安装失败（退出码 {process.ExitCode}）。");

        var stateRoot = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "CodexDreamSkin");
        var engineVersion = Path.Combine(stateRoot, "engine", "VERSION");
        if (!Directory.Exists(stateRoot) || !File.Exists(engineVersion))
            throw new InvalidOperationException("Codex Dream Skin 安装后未找到受管运行时。");
        var seeded = SeedBundledCommunityThemes(setupPath);
        var galleryCatalogConnected = false;
        if (openGallery)
        {
            progress.Report(new InstallerEvent(
                "dream_skin_gallery_api", 0.955,
                "正在连接 DreamSkin.cc API，准备更多主题选择",
                null));
            galleryCatalogConnected = await TryRefreshGalleryCatalogAsync(
                stateRoot,
                cancellationToken).ConfigureAwait(false);
            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = GalleryUrl,
                    UseShellExecute = true
                });
            }
            catch
            {
                // Opening the browser is an optional convenience; installation remains successful.
            }
        }
        var installedMessage = openGallery
            ? galleryCatalogConnected
                ? $"Codex Dream Skin 已安装（已预装 {seeded} 套精选主题，已连接 DreamSkin.cc API）"
                : $"Codex Dream Skin 已安装（已预装 {seeded} 套精选主题；主题库连接稍后可重试）"
            : $"Codex Dream Skin 已安装（Gothic Void Crusade，已预装 {seeded} 套精选主题）";
        progress.Report(new InstallerEvent(
            "dream_skin_installed", 0.96, installedMessage, null));
    }

    private static async Task<bool> TryRefreshGalleryCatalogAsync(
        string stateRoot,
        CancellationToken cancellationToken)
    {
        try
        {
            using var response = await GalleryApiClient.GetAsync(
                GalleryApiUrl,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
                return false;

            var payload = await response.Content.ReadAsByteArrayAsync(
                cancellationToken).ConfigureAwait(false);
            using var document = JsonDocument.Parse(payload);
            if (!document.RootElement.TryGetProperty("items", out var items) ||
                items.ValueKind != JsonValueKind.Array ||
                items.GetArrayLength() == 0)
                return false;

            Directory.CreateDirectory(stateRoot);
            var destination = Path.Combine(stateRoot, "gallery-api-catalog.json");
            var temporary = destination + ".tmp";
            await File.WriteAllBytesAsync(temporary, payload, cancellationToken)
                .ConfigureAwait(false);
            File.Move(temporary, destination, overwrite: true);
            return true;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (HttpRequestException)
        {
            return false;
        }
        catch (TaskCanceledException)
        {
            return false;
        }
        catch (JsonException)
        {
            return false;
        }
        catch (IOException)
        {
            return false;
        }
    }

    private static int SeedBundledCommunityThemes(string setupPath)
    {
        var setupDirectory = Path.GetDirectoryName(Path.GetFullPath(setupPath))
            ?? throw new InvalidOperationException("Dream Skin 安装包目录无效。");
        var sourceRoot = Path.Combine(setupDirectory, "themes");
        if (!Directory.Exists(sourceRoot))
            throw new InvalidOperationException("安装包未包含 DreamSkin.cc 精选主题。");

        var destinationRoot = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "CodexDreamSkin",
            "themes");
        Directory.CreateDirectory(destinationRoot);
        var count = 0;
        foreach (var source in Directory.EnumerateDirectories(sourceRoot))
        {
            var directoryName = Path.GetFileName(source);
            if (string.IsNullOrWhiteSpace(directoryName) ||
                directoryName.Any(character =>
                    !(char.IsLetterOrDigit(character) || character is '-' or '_' or '.')))
                throw new InvalidOperationException("精选主题目录名无效。");
            var manifestPath = Path.Combine(source, "manifest.json");
            if (!File.Exists(manifestPath))
                throw new InvalidOperationException($"精选主题缺少 manifest.json：{directoryName}");
            using var manifest = JsonDocument.Parse(File.ReadAllBytes(manifestPath));
            var root = manifest.RootElement;
            var themeId = root.GetProperty("themeId").GetString();
            if (!string.Equals(themeId, directoryName, StringComparison.Ordinal) ||
                !root.GetProperty("platforms").EnumerateArray()
                    .Any(item => string.Equals(item.GetString(), "windows", StringComparison.OrdinalIgnoreCase)))
                throw new InvalidOperationException($"精选主题不支持 Windows：{directoryName}");
            var destination = Path.Combine(destinationRoot, directoryName);
            CopyThemeDirectory(source, destination);
            count++;
        }
        if (count != 10)
            throw new InvalidOperationException($"精选主题数量不正确：{count}（应为 10）。");
        return count;
    }

    private static void CopyThemeDirectory(string source, string destination)
    {
        var sourceInfo = new DirectoryInfo(source);
        if ((sourceInfo.Attributes & FileAttributes.ReparsePoint) != 0)
            throw new IOException("精选主题目录不能包含符号链接或重解析点。");
        Directory.CreateDirectory(destination);
        foreach (var entry in sourceInfo.EnumerateFileSystemInfos())
        {
            if ((entry.Attributes & FileAttributes.ReparsePoint) != 0)
                throw new IOException("精选主题载荷不能包含符号链接或重解析点。");
            var target = Path.Combine(destination, entry.Name);
            if (entry is DirectoryInfo)
                CopyThemeDirectory(entry.FullName, target);
            else
                File.Copy(entry.FullName, target, overwrite: true);
        }
    }
}
