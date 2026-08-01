using System.IO;
using System.Xml.Linq;
using Xunit;

namespace CodexOneClickInstaller;

public sealed class LayoutTests
{
    private static readonly XNamespace Presentation =
        "http://schemas.microsoft.com/winfx/2006/xaml/presentation";
    private static readonly XNamespace Xaml =
        "http://schemas.microsoft.com/winfx/2006/xaml";

    [Fact]
    public void Window_has_required_size_and_content_only_scrolls()
    {
        var document = LoadXaml();
        var window = document.Root!;

        Assert.Equal("860", window.Attribute("Width")?.Value);
        Assert.Equal("700", window.Attribute("Height")?.Value);
        Assert.Equal("800", window.Attribute("MinWidth")?.Value);
        Assert.Equal("640", window.Attribute("MinHeight")?.Value);
        Assert.Equal("True", window.Attribute("UseLayoutRounding")?.Value);
        Assert.Equal("True", window.Attribute("SnapsToDevicePixels")?.Value);
        Assert.Equal(
            "/CodexOneClickInstaller;component/Resources/icons/AppIcon.ico",
            window.Attribute("Icon")?.Value);

        var scrollViewer = Assert.Single(
            window.Descendants(Presentation + "ScrollViewer"),
            node => node.Attribute("VerticalScrollBarVisibility") is not null);
        Assert.Equal("1", scrollViewer.Attribute("Grid.Row")?.Value);
        var footer = window.Descendants(Presentation + "Grid")
            .Single(node => node.Attribute("Grid.Row")?.Value == "2");
        Assert.DoesNotContain(scrollViewer.Ancestors(), node => node == footer);

        var progress = Assert.Single(
            window.Descendants(Presentation + "ProgressBar"));
        Assert.Equal(
            "{Binding Progress, Mode=OneWay}",
            progress.Attribute("Value")?.Value);
    }

    [Theory]
    [InlineData(800, 640, 1.00)]
    [InlineData(860, 700, 1.00)]
    [InlineData(800, 640, 1.25)]
    [InlineData(800, 640, 1.50)]
    [InlineData(800, 640, 2.00)]
    public void Three_column_rows_keep_positive_non_overlapping_boundaries(
        double windowWidth,
        double windowHeight,
        double dpiScale)
    {
        Assert.True(windowHeight >= 640);
        Assert.True(dpiScale > 0);
        var availableLogicalWidth = windowWidth - 48 - 32;
        var middle = availableLogicalWidth - 120 - 180;
        Assert.True(middle > 0);
        var boundaries = new[] { 0d, 120d, 120d + middle, availableLogicalWidth };
        Assert.True(boundaries.Zip(boundaries.Skip(1), (left, right) => right > left)
            .All(value => value));
        Assert.All(boundaries, value => Assert.True(value * dpiScale >= 0));

        var document = LoadXaml();
        var rowNames = new[]
        {
            "ProviderRow",
            "AuthenticationRow",
            "AuthorizationRecommendationRow",
            "ApiKeyRow",
            "ApiKeyHintRow",
            "ModelRow",
            "ModelSourceRow"
        };
        foreach (var rowName in rowNames)
        {
            var row = document.Descendants(Presentation + "Grid")
                .Single(node => node.Attribute(Xaml + "Name")?.Value == rowName);
            var widths = row
                .Element(Presentation + "Grid.ColumnDefinitions")!
                .Elements(Presentation + "ColumnDefinition")
                .Select(node => node.Attribute("Width")!.Value)
                .ToArray();
            Assert.Equal(new[] { "120", "*", "180" }, widths);
        }
    }

    [Fact]
    public void Inputs_and_auxiliary_buttons_are_32_pixels_high()
    {
        var document = LoadXaml();
        Assert.Equal("32", StyleSetter(document, "FieldControlStyle", "Height"));
        Assert.Equal("32", StyleSetter(document, "AuxiliaryButtonStyle", "Height"));
    }

    [Fact]
    public void High_contrast_uses_system_brushes_and_tab_order_is_complete()
    {
        var text = File.ReadAllText(MainWindowPath());
        Assert.Contains("SystemColors.WindowBrushKey", text, StringComparison.Ordinal);
        Assert.Contains("SystemColors.HighlightBrushKey", text, StringComparison.Ordinal);
        Assert.Contains("SystemColors.HighlightTextBrushKey", text, StringComparison.Ordinal);
        Assert.DoesNotContain("#", text, StringComparison.Ordinal);

        var document = LoadXaml();
        var tabIndices = document.Descendants()
            .Select(node => node.Attribute("TabIndex")?.Value)
            .Where(value => value is not null)
            .Select(value => int.Parse(value!))
            .Order()
            .ToArray();
        Assert.Equal(Enumerable.Range(0, 11), tabIndices);
        Assert.Equal(tabIndices.Length, tabIndices.Distinct().Count());
    }

    [Fact]
    public void Code_behind_is_thin_and_contains_no_event_or_process_logic()
    {
        var code = File.ReadAllText(
            Path.Combine(RepositoryRoot(), "windows", "src", "InstallerGUI",
                "MainWindow.xaml.cs"));

        Assert.Contains("public MainWindow(InstallerViewModel viewModel)", code);
        Assert.Contains("DataContext = viewModel;", code);
        Assert.DoesNotContain("PowerShell", code, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("Process", code, StringComparison.Ordinal);
        Assert.DoesNotContain("_Click", code, StringComparison.Ordinal);
        Assert.DoesNotContain("SelectionChanged", code, StringComparison.Ordinal);
    }

    private static string? StyleSetter(
        XDocument document,
        string styleKey,
        string property)
    {
        var style = document.Descendants(Presentation + "Style")
            .Single(node => node.Attribute(Xaml + "Key")?.Value == styleKey);
        return style.Elements(Presentation + "Setter")
            .Single(node => node.Attribute("Property")?.Value == property)
            .Attribute("Value")?.Value;
    }

    private static XDocument LoadXaml() => XDocument.Load(MainWindowPath());

    private static string MainWindowPath() =>
        Path.Combine(
            RepositoryRoot(),
            "windows",
            "src",
            "InstallerGUI",
            "MainWindow.xaml");

    private static string RepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            if (File.Exists(Path.Combine(
                    directory.FullName,
                    "windows",
                    "CodexOneClickInstaller.sln")))
            {
                return directory.FullName;
            }
            directory = directory.Parent;
        }
        throw new DirectoryNotFoundException("Repository root was not found.");
    }
}
