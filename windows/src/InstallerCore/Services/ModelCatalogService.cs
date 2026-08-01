using System.Net.Http.Headers;
using System.Text.Json;

namespace CodexOneClickInstaller;

public sealed record ModelResolution(
    IReadOnlyList<ModelDefinition> Models,
    ModelSource Source);

public sealed class ModelCatalogService
{
    private readonly HttpClient httpClient;
    private readonly IReadOnlyDictionary<ProviderKind, IReadOnlyList<ModelDefinition>>
        offlineSnapshot;

    public ModelCatalogService(
        string catalogPath,
        HttpClient? httpClient = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(catalogPath);
        this.httpClient = httpClient ?? new HttpClient();
        offlineSnapshot = Load(catalogPath);
        ValidateRequiredModels();
    }

    public IReadOnlyList<ModelDefinition> OfflineModels(ProviderKind provider) =>
        offlineSnapshot.TryGetValue(provider, out var models)
            ? models
            : throw new InvalidDataException("Provider is absent from model catalog.");

    public async Task<ModelResolution> ResolveModelsAsync(
        ProviderKind provider,
        SensitiveString apiKey,
        IEnumerable<string>? customModelIds = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(apiKey);
        var custom = NormalizeCustom(customModelIds ?? []);
        try
        {
            using var request = new HttpRequestMessage(
                HttpMethod.Get,
                InstallerConfig.Provider(provider).ModelsUrl);
            request.Headers.Authorization = new AuthenticationHeaderValue(
                "Bearer",
                apiKey.RevealForConfigurationWrite().Trim());
            request.Headers.Accept.Add(
                new MediaTypeWithQualityHeaderValue("application/json"));
            using var response = await httpClient.SendAsync(
                    request,
                    HttpCompletionOption.ResponseHeadersRead,
                    cancellationToken)
                .ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
                throw new InvalidDataException("Upstream models request failed.");
            await using var content = await response.Content
                .ReadAsStreamAsync(cancellationToken)
                .ConfigureAwait(false);
            var refreshed = await ParseResponseAsync(content, cancellationToken)
                .ConfigureAwait(false);
            return new ModelResolution(
                Merge(refreshed, custom),
                ModelSource.UpstreamRefresh);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception error) when (error is HttpRequestException
                                      or IOException
                                      or JsonException
                                      or InvalidDataException)
        {
            return new ModelResolution(
                Merge(OfflineModels(provider), custom),
                ModelSource.OfflineSnapshot);
        }
    }

    private static async Task<IReadOnlyList<ModelDefinition>> ParseResponseAsync(
        Stream stream,
        CancellationToken cancellationToken)
    {
        using var document = await JsonDocument.ParseAsync(
                stream,
                cancellationToken: cancellationToken)
            .ConfigureAwait(false);
        if (document.RootElement.ValueKind != JsonValueKind.Object
            || !document.RootElement.TryGetProperty("data", out var data)
            || data.ValueKind != JsonValueKind.Array)
        {
            throw new InvalidDataException("Upstream models response has an unknown shape.");
        }

        var models = new List<ModelDefinition>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in data.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.Object
                || !item.TryGetProperty("id", out var idNode)
                || idNode.ValueKind != JsonValueKind.String)
            {
                continue;
            }
            var id = idNode.GetString();
            if (!InstallerConfig.IsLegalModelId(id)
                || !seen.Add(id!))
            {
                continue;
            }
            models.Add(new ModelDefinition(id!, id!, null));
        }

        if (models.Count == 0)
            throw new InvalidDataException("Upstream returned no legal model IDs.");
        return models
            .OrderBy(model => model.Id, StringComparer.Ordinal)
            .ToArray();
    }

    private static IReadOnlyList<ModelDefinition> Merge(
        IEnumerable<ModelDefinition> models,
        IEnumerable<ModelDefinition> custom)
    {
        var merged = new Dictionary<string, ModelDefinition>(StringComparer.Ordinal);
        foreach (var model in models.Concat(custom))
        {
            if (InstallerConfig.IsLegalModelId(model.Id))
                merged.TryAdd(model.Id, model);
        }
        return merged.Values
            .OrderBy(model => model.Id, StringComparer.Ordinal)
            .ToArray();
    }

    private static IReadOnlyList<ModelDefinition> NormalizeCustom(
        IEnumerable<string> ids) =>
        ids.Where(InstallerConfig.IsLegalModelId)
            .Distinct(StringComparer.Ordinal)
            .Select(id => new ModelDefinition(id, id, null))
            .ToArray();

    private static IReadOnlyDictionary<ProviderKind, IReadOnlyList<ModelDefinition>>
        Load(string path)
    {
        using var document = JsonDocument.Parse(File.ReadAllBytes(path));
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object
            || !root.TryGetProperty("schemaVersion", out var schema)
            || schema.GetInt32() != 1
            || !root.TryGetProperty("providers", out var providers)
            || providers.ValueKind != JsonValueKind.Array)
        {
            throw new InvalidDataException("Invalid model catalog.");
        }

        var mapped =
            new Dictionary<ProviderKind, IReadOnlyList<ModelDefinition>>();
        foreach (var item in providers.EnumerateArray())
        {
            var provider = JsonSerializer.Deserialize<ProviderKind>(
                item.GetProperty("kind").GetRawText());
            if (!string.Equals(
                    item.GetProperty("protocolName").GetString(),
                    "chatCompletions",
                    StringComparison.Ordinal)
                || !mapped.TryAdd(provider, ParseCatalogModels(item)))
            {
                throw new InvalidDataException("Invalid provider model catalog.");
            }
        }
        if (mapped.Count != Enum.GetValues<ProviderKind>().Length
            || Enum.GetValues<ProviderKind>().Any(provider => !mapped.ContainsKey(provider)))
        {
            throw new InvalidDataException(
                "Model catalog must contain every supported provider exactly once.");
        }
        return mapped;
    }

    private static IReadOnlyList<ModelDefinition> ParseCatalogModels(
        JsonElement provider)
    {
        var models = new List<ModelDefinition>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in provider.GetProperty("models").EnumerateArray())
        {
            var id = item.GetProperty("id").GetString();
            var name = item.GetProperty("displayName").GetString();
            var context = item.TryGetProperty("contextWindow", out var contextNode)
                          && contextNode.ValueKind == JsonValueKind.Number
                ? contextNode.GetInt32()
                : (int?)null;
            if (!InstallerConfig.IsLegalModelId(id)
                || string.IsNullOrWhiteSpace(name)
                || context is <= 0
                || !seen.Add(id!))
            {
                throw new InvalidDataException("Invalid offline model.");
            }
            models.Add(new ModelDefinition(id!, name!, context));
        }
        if (models.Count == 0)
            throw new InvalidDataException("Offline provider model list is empty.");
        return models
            .OrderBy(model => model.Id, StringComparer.Ordinal)
            .ToArray();
    }

    private void ValidateRequiredModels()
    {
        foreach (var provider in Enum.GetValues<ProviderKind>())
        {
            var ids = OfflineModels(provider)
                .Select(model => model.Id)
                .ToHashSet(StringComparer.Ordinal);
            if (!InstallerConfig.Provider(provider)
                .RequiredOfflineModels.All(ids.Contains))
            {
                throw new InvalidDataException(
                    "Offline model catalog is missing a required provider model.");
            }
        }
    }
}
