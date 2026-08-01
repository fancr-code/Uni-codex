using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CodexOneClickInstaller;

public sealed class RedactingLogger
{
    private readonly object gate = new();
    private readonly List<string> messages = [];
    private readonly HashSet<string> secrets = new(StringComparer.Ordinal);

    public IReadOnlyList<string> Messages
    {
        get
        {
            lock (gate)
                return messages.ToArray();
        }
    }

    public void AddSecret(SensitiveString secret)
    {
        ArgumentNullException.ThrowIfNull(secret);
        var value = secret.RevealForConfigurationWrite();
        lock (gate)
        {
            secrets.Add(value);
            secrets.Add(Convert.ToHexString(
                    SHA256.HashData(Encoding.UTF8.GetBytes(value)))
                .ToLowerInvariant());
        }
    }

    public void AddSensitivePath(string? path)
    {
        if (string.IsNullOrWhiteSpace(path))
            return;
        var fullPath = Path.GetFullPath(path);
        var root = Path.GetPathRoot(fullPath);
        var normalized = Path.TrimEndingDirectorySeparator(fullPath);
        if (string.IsNullOrEmpty(normalized)
            || string.Equals(
                Path.TrimEndingDirectorySeparator(root ?? string.Empty),
                normalized,
                StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        lock (gate)
        {
            AddPathVariant(normalized);
            AddPathVariant(normalized.Replace('\\', '/'));
            AddPathVariant(normalized.Replace('/', '\\'));
        }
    }

    public void Log(string message)
    {
        lock (gate)
            messages.Add(RedactCore(message));
    }

    public string Redact(string value)
    {
        lock (gate)
            return RedactCore(value);
    }

    private string RedactCore(string value)
    {
        var redacted = InstallerConfig.Redact(value ?? string.Empty);
        foreach (var secret in secrets.OrderByDescending(
                     item => item.Length))
        {
            if (!string.IsNullOrEmpty(secret))
            {
                redacted = redacted.Replace(
                    secret,
                    "[REDACTED]",
                    StringComparison.OrdinalIgnoreCase);
            }
        }
        return redacted;
    }

    private void AddPathVariant(string value)
    {
        if (string.IsNullOrEmpty(value))
            return;
        secrets.Add(value);
        var escaped = JsonSerializer.Serialize(value);
        if (escaped.Length >= 2)
            secrets.Add(escaped[1..^1]);
    }
}

public sealed class InstallerReportWriter
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() }
    };

    private readonly string reportDirectory;

    public InstallerReportWriter(string reportDirectory)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(reportDirectory);
        this.reportDirectory = Path.GetFullPath(reportDirectory);
    }

    public async Task<string> WriteAsync(
        InstallerReport report,
        RedactingLogger logger,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(report);
        ArgumentNullException.ThrowIfNull(logger);
        Directory.CreateDirectory(reportDirectory);
        var path = Path.Combine(reportDirectory, "install-report.json");
        var json = logger.Redact(JsonSerializer.Serialize(report, JsonOptions));
        await File.WriteAllTextAsync(
                path,
                json + Environment.NewLine,
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: false),
                cancellationToken)
            .ConfigureAwait(false);
        return path;
    }
}
