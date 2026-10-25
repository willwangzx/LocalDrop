using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Windows;
using Microsoft.Win32;
namespace LocalDrop;
public partial class MainWindow : Window
{
    private readonly TransferServer server = new();
    private readonly ObservableCollection<SharedFile> files = new();
    public MainWindow()
    {
        InitializeComponent();
        FilesList.ItemsSource = files;
        SecretBox.Text = server.Secret;
        server.Status = message => Dispatcher.InvokeAsync(() => StatusText.Text = message);
        Loaded += async (_, _) => {
            try {
                await server.StartAsync();
                var addresses = Dns.GetHostAddresses(Dns.GetHostName())
                    .Where(a => a.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(a));
                AddressBox.Text = string.Join(Environment.NewLine, addresses.Select(a => $"http://{a}:45872"));
                StatusText.Text = "Ready. Allow LocalDrop through Windows Firewall on private networks when prompted.";
            } catch (Exception ex) { StatusText.Text = $"Could not start: {ex.Message}"; }
        };
        Closed += async (_, _) => await server.DisposeAsync();
    }
    private void AddFiles(object sender, RoutedEventArgs e)
    {
        var picker = new OpenFileDialog { Multiselect = true, Title = "Share files with iPhone" };
        if (picker.ShowDialog() != true) return;
        foreach (var path in picker.FileNames) {
            try { files.Add(server.Share(path)); }
            catch (Exception ex) { StatusText.Text = ex.Message; }
        }
    }
    private void RemoveFiles(object sender, RoutedEventArgs e)
    {
        foreach (var file in FilesList.SelectedItems.Cast<SharedFile>().ToArray()) {
            server.Unshare(file.Id); files.Remove(file);
        }
    }
    private void OpenReceived(object sender, RoutedEventArgs e) =>
        Process.Start(new ProcessStartInfo(server.ReceiveDirectory) { UseShellExecute = true });
}
