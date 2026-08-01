#if WINDOWS
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Xunit;

namespace CodexOneClickInstaller;

public sealed class RuntimeLayoutTests
{
    private static readonly string[] ConfigurationRows =
    [
        "ProviderRow",
        "AuthenticationRow",
        "AuthorizationRecommendationRow",
        "ApiKeyRow",
        "ApiKeyHintRow",
        "ModelRow",
        "ModelSourceRow"
    ];

    [Theory]
    [InlineData(800, 640)]
    [InlineData(860, 700)]
    public void MainWindow_measure_and_arrange_has_no_negative_or_overlapping_columns(
        double width,
        double height)
    {
        if (!OperatingSystem.IsWindows())
            return;

        RunOnSta(() =>
        {
            var viewModel = new InstallerViewModel(new RuntimeBackend());
            viewModel.SelectedAuthentication =
                viewModel.AuthenticationModes.Single(mode =>
                    mode.Value == AuthenticationMode.OpenAIAccountWithApi);
            var window = new MainWindow(viewModel)
            {
                Width = width,
                Height = height
            };

            MeasureAndArrange(window, width, height);

            foreach (var rowName in ConfigurationRows)
            {
                var row = Assert.IsType<Grid>(window.FindName(rowName));
                Assert.True(row.ActualWidth > 0);
                Assert.Equal(3, row.ColumnDefinitions.Count);
                Assert.InRange(
                    row.ColumnDefinitions[0].ActualWidth,
                    119.5,
                    120.5);
                Assert.True(row.ColumnDefinitions[1].ActualWidth > 0);
                Assert.InRange(
                    row.ColumnDefinitions[2].ActualWidth,
                    179.5,
                    180.5);
                AssertNoOverlappingChildren(row);

                foreach (var dpiScale in new[] { 1.0, 1.25, 1.5, 2.0 })
                    AssertScaledColumnEdges(row, dpiScale);
            }

            CaptureLayoutEvidenceIfRequested(window, (int)width, (int)height);
            window.Close();
        });
    }

    private static void CaptureLayoutEvidenceIfRequested(
        Window window,
        int width,
        int height)
    {
        var outputDirectory =
            Environment.GetEnvironmentVariable("CODEX_LAYOUT_SCREENSHOT_DIR");
        if (string.IsNullOrWhiteSpace(outputDirectory))
            return;

        var root = Path.GetFullPath(outputDirectory);
        Directory.CreateDirectory(root);
        var bitmap = new RenderTargetBitmap(
            width,
            height,
            96,
            96,
            PixelFormats.Pbgra32);
        bitmap.Render(Assert.IsAssignableFrom<FrameworkElement>(window.Content));
        var pixels = new byte[width * height * 4];
        bitmap.CopyPixels(pixels, width * 4, 0);
        var hasVariation = false;
        for (var offset = 4; offset < pixels.Length; offset += 4)
        {
            if (pixels[offset] != pixels[0]
                || pixels[offset + 1] != pixels[1]
                || pixels[offset + 2] != pixels[2]
                || pixels[offset + 3] != pixels[3])
            {
                hasVariation = true;
                break;
            }
        }
        Assert.True(hasVariation, "Rendered layout screenshot is blank.");
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        var path = Path.Combine(root, $"main-window-{width}x{height}.png");
        using (var stream = File.Create(path))
            encoder.Save(stream);

        var bytes = File.ReadAllBytes(path);
        Assert.True(bytes.Length > 8);
        Assert.Equal(
            new byte[] { 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a },
            bytes[..8]);
    }

    [Fact]
    public void MainWindow_runtime_bindings_resolve_without_errors()
    {
        if (!OperatingSystem.IsWindows())
            return;

        RunOnSta(() =>
        {
            var listener = new BindingErrorListener();
            var source = PresentationTraceSources.DataBindingSource;
            var originalLevel = source.Switch.Level;
            source.Switch.Level = SourceLevels.Error;
            source.Listeners.Add(listener);
            try
            {
                var window = new MainWindow(
                    new InstallerViewModel(new RuntimeBackend()));
                MeasureAndArrange(window, 860, 700);
                Dispatcher.CurrentDispatcher.Invoke(
                    () => { },
                    DispatcherPriority.ApplicationIdle);

                Assert.Empty(listener.Messages);
                Assert.NotNull(
                    BindingOperations.GetBindingExpression(
                        Assert.IsType<ComboBox>(
                            window.FindName("ProviderComboBox")),
                        ItemsControl.ItemsSourceProperty));
                window.Close();
            }
            finally
            {
                source.Listeners.Remove(listener);
                source.Switch.Level = originalLevel;
            }
        });
    }

    private static void MeasureAndArrange(
        Window window,
        double width,
        double height)
    {
        var content = Assert.IsAssignableFrom<FrameworkElement>(window.Content);
        content.Measure(new Size(width, height));
        content.Arrange(new Rect(0, 0, width, height));
        content.UpdateLayout();
        Assert.True(content.ActualWidth > 0);
        Assert.True(content.ActualHeight > 0);
    }

    private static void AssertScaledColumnEdges(Grid row, double dpiScale)
    {
        var left = 0d;
        foreach (var column in row.ColumnDefinitions)
        {
            var right = left + column.ActualWidth * dpiScale;
            Assert.True(right > left);
            left = right;
        }
        Assert.InRange(
            left,
            row.ActualWidth * dpiScale - 0.5,
            row.ActualWidth * dpiScale + 0.5);
    }

    private static void AssertNoOverlappingChildren(Grid row)
    {
        var children = row.Children
            .OfType<FrameworkElement>()
            .Where(child => child.Visibility == Visibility.Visible)
            .ToArray();
        Assert.All(children, child =>
        {
            Assert.True(child.ActualWidth >= 0);
            Assert.True(child.ActualHeight >= 0);
        });

        foreach (var left in children)
        {
            var leftLastColumn =
                Grid.GetColumn(left) + Math.Max(Grid.GetColumnSpan(left), 1) - 1;
            var leftRight = left.TranslatePoint(
                new Point(left.ActualWidth, 0),
                row).X;
            foreach (var right in children)
            {
                if (leftLastColumn >= Grid.GetColumn(right))
                    continue;
                var rightLeft = right.TranslatePoint(new Point(0, 0), row).X;
                Assert.True(
                    leftRight <= rightLeft + 0.5,
                    $"{left.Name} overlaps {right.Name} in {row.Name}.");
            }
        }
    }

    private static void RunOnSta(Action action)
    {
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try
            {
                action();
            }
            catch (Exception error)
            {
                failure = error;
            }
            finally
            {
                Dispatcher.CurrentDispatcher.InvokeShutdown();
            }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        if (failure is not null)
            throw new Xunit.Sdk.XunitException(
                $"WPF STA assertion failed: {failure}");
    }

    private sealed class BindingErrorListener : TraceListener
    {
        public List<string> Messages { get; } = [];

        public override void Write(string? message)
        {
            if (!string.IsNullOrWhiteSpace(message))
                Messages.Add(message);
        }

        public override void WriteLine(string? message) => Write(message);
    }

    private sealed class RuntimeBackend : IInstallerBackend
    {
        private static readonly IReadOnlyDictionary<
            ProviderKind,
            IReadOnlyList<ModelDefinition>> Models =
            new Dictionary<ProviderKind, IReadOnlyList<ModelDefinition>>
            {
                [ProviderKind.DeepSeek] =
                [
                    new("deepseek-v4-flash", "DeepSeek V4 Flash", 1_000_000)
                ],
                [ProviderKind.KimiOpen] =
                [
                    new("kimi-k3", "Kimi K3", 1_000_000)
                ],
                [ProviderKind.KimiCode] =
                [
                    new("k3", "Kimi K3", 1_048_576)
                ]
            };

        public OpenAIAuthorizationSnapshot Authorization { get; } =
            new(true, false, "获取 OpenAI 授权");

        public bool CanRestore => false;

        public IReadOnlyList<ModelDefinition> OfflineModels(
            ProviderKind provider) =>
            Models[provider];

        public Task<ModelResolution> RefreshModelsAsync(
            ProviderKind provider,
            SensitiveString apiKey,
            CancellationToken cancellationToken) =>
            Task.FromResult(new ModelResolution(
                Models[provider],
                ModelSource.OfflineSnapshot));

        public Task<OpenAIAuthorizationSnapshot> RefreshAuthorizationAsync(
            CancellationToken cancellationToken) =>
            Task.FromResult(Authorization);

        public Task<OpenAIAuthorizationSnapshot> AuthorizeAsync(
            IProgress<OpenAIAuthorizationSnapshot> progress,
            CancellationToken cancellationToken) =>
            Task.FromResult(Authorization);

        public Task<InstallerUiResult> InstallAsync(
            InstallRequest request,
            IProgress<InstallerEvent> progress,
            CancellationToken cancellationToken) =>
            Task.FromResult(new InstallerUiResult(true));

        public Task<RestoreResult> RestoreLatestAsync(
            CancellationToken cancellationToken) =>
            Task.FromResult(new RestoreResult(false));

        public void CancelAuthorization()
        {
        }
    }
}
#endif
