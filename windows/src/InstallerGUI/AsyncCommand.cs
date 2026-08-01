using System.Windows.Input;

namespace CodexOneClickInstaller;

public sealed class AsyncCommand : ICommand
{
    private readonly Func<Task> execute;
    private readonly Func<bool> canExecute;
    private bool isExecuting;

    public AsyncCommand(Func<Task> execute, Func<bool>? canExecute = null)
    {
        this.execute = execute ?? throw new ArgumentNullException(nameof(execute));
        this.canExecute = canExecute ?? (() => true);
    }

    public event EventHandler? CanExecuteChanged;

    public bool CanExecute(object? parameter) =>
        !isExecuting && canExecute();

    public async void Execute(object? parameter) =>
        await ExecuteAsync();

    public async Task ExecuteAsync()
    {
        if (!CanExecute(null))
            return;

        isExecuting = true;
        RaiseCanExecuteChanged();
        try
        {
            await execute();
        }
        finally
        {
            isExecuting = false;
            RaiseCanExecuteChanged();
        }
    }

    public void RaiseCanExecuteChanged() =>
        CanExecuteChanged?.Invoke(this, EventArgs.Empty);
}

public sealed class DelegateCommand : ICommand
{
    private readonly Action execute;
    private readonly Func<bool> canExecute;

    public DelegateCommand(Action execute, Func<bool>? canExecute = null)
    {
        this.execute = execute ?? throw new ArgumentNullException(nameof(execute));
        this.canExecute = canExecute ?? (() => true);
    }

    public event EventHandler? CanExecuteChanged;

    public bool CanExecute(object? parameter) => canExecute();

    public void Execute(object? parameter) => execute();

    public void RaiseCanExecuteChanged() =>
        CanExecuteChanged?.Invoke(this, EventArgs.Empty);
}
