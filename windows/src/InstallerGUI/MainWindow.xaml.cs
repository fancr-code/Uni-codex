using System.Windows;

namespace CodexOneClickInstaller;

public partial class MainWindow : Window
{
    public MainWindow(InstallerViewModel viewModel)
    {
        InitializeComponent();
        DataContext = viewModel;
    }
}
