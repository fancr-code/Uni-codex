using System.Diagnostics;
using System.IO;

namespace CodexOneClickInstaller;

internal static class DreamSkinInstaller
{
    public const string GothicPreset = "preset-gothic-void-crusade";
    public const string NonePreset = "none";

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
        if (!string.Equals(preset, GothicPreset, StringComparison.Ordinal))
            throw new InvalidOperationException("不支持的 Dream Skin 预设。");
        if (string.IsNullOrWhiteSpace(setupPath) ||
            !File.Exists(setupPath))
            throw new FileNotFoundException("安装包未包含 Codex Dream Skin 安装程序。", setupPath);

        progress.Report(new InstallerEvent(
            "dream_skin_installing", 0.91, "正在安装 Codex Dream Skin（Gothic Void Crusade）", null));
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
        progress.Report(new InstallerEvent(
            "dream_skin_installed", 0.96, "Codex Dream Skin 已安装（Gothic Void Crusade）", null));
    }
}
