using System.Collections.Concurrent;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace LocalDrop;
public record SharedFile(string Id, string Name, long Size);
public sealed class TransferServer : IAsyncDisposable
{
    public const long MaxFileSize = 100L * 1024 * 1024 * 1024;
    public string Secret { get; } = Convert.ToHexString(RandomNumberGenerator.GetBytes(16));
    public string ReceiveDirectory { get; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "LocalDrop", "Received");
    public TransferServer(string? receiveDirectory = null) {
        if (receiveDirectory is not null) ReceiveDirectory = receiveDirectory;
    }
    public Action<string>? Status { get; set; }
    private readonly ConcurrentDictionary<string, string> shared = new();
    private readonly SemaphoreSlim uploadSlots = new(2);
    private WebApplication? app;
    public SharedFile Share(string path) {
        var info = new FileInfo(path);
        var item = new SharedFile(Guid.NewGuid().ToString("N"), info.Name, info.Length);
        shared[item.Id] = info.FullName;
        return item;
    }
    public void Unshare(string id) => shared.TryRemove(id, out _);
    public async Task StartAsync()
    {
        Directory.CreateDirectory(ReceiveDirectory);
        var builder = WebApplication.CreateSlimBuilder();
        builder.Logging.ClearProviders();
        builder.WebHost.UseKestrel(options => {
            options.ListenAnyIP(45872);
            options.Limits.MaxRequestBodySize = MaxFileSize;
        });
        app = builder.Build();
        app.Use(async (context, next) => {
            var supplied = Encoding.UTF8.GetBytes(context.Request.Headers.Authorization.ToString());
            var expected = Encoding.UTF8.GetBytes("Bearer " + Secret);
            if (!CryptographicOperations.FixedTimeEquals(supplied, expected)) {
                context.Response.StatusCode = 401; return;
            }
            context.Response.Headers.CacheControl = "no-store";
            await next(context);
        });
        app.MapGet("/v1/info", () => Results.Ok(new { name = Environment.MachineName, protocol = 1, maxFileSize = MaxFileSize }));
        app.MapGet("/v1/files", () => {
            var items = new List<SharedFile>();
            foreach (var pair in shared) {
                try { var file = new FileInfo(pair.Value); if (file.Exists) items.Add(new(pair.Key, file.Name, file.Length)); }
                catch (IOException) { }
            }
            return Results.Ok(items.OrderBy(f => f.Name));
        });
        app.MapGet("/v1/files/{id}", (string id) => {
            if (!shared.TryGetValue(id, out var path) || !File.Exists(path)) return Results.NotFound();
            return Results.File(path, "application/octet-stream", Path.GetFileName(path), enableRangeProcessing: true);
        });
        app.MapPost("/v1/upload", async (HttpContext context) => {
            if (context.Request.ContentLength is not long length || length < 0) return Results.StatusCode(411);
            if (length > MaxFileSize) return Results.StatusCode(413);
            if (!await uploadSlots.WaitAsync(0, context.RequestAborted)) return Results.StatusCode(429);
            var temp = Path.Combine(ReceiveDirectory, "." + Guid.NewGuid().ToString("N") + ".partial");
            try {
                var name = SafeName(context.Request.Query["name"].ToString());
                var drive = new DriveInfo(Path.GetPathRoot(ReceiveDirectory)!);
                if (drive.AvailableFreeSpace < length + 64 * 1024 * 1024) return Results.StatusCode(507);
                long received = 0;
                await using (var output = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1024 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan)) {
                    var buffer = new byte[1024 * 1024];
                    var lastUpdate = Environment.TickCount64;
                    int count;
                    while ((count = await context.Request.Body.ReadAsync(buffer, context.RequestAborted)) > 0) {
                        received += count;
                        if (received > length) return Results.BadRequest(new { error = "Length mismatch" });
                        await output.WriteAsync(buffer.AsMemory(0, count), context.RequestAborted);
                        if (Environment.TickCount64 - lastUpdate > 500) {
                            Status?.Invoke($"Receiving {name}: {received / 1048576.0:F1} / {length / 1048576.0:F1} MB");
                            lastUpdate = Environment.TickCount64;
                        }
                    }
                }
                if (received != length) return Results.BadRequest(new { error = "Incomplete transfer" });
                // Unique destination avoids overwriting an existing user file or a concurrent upload.
                var savedName = $"{Guid.NewGuid():N}_{name}";
                File.Move(temp, Path.Combine(ReceiveDirectory, savedName));
                Status?.Invoke($"Received {name} ({received / 1048576.0:F1} MB)");
                return Results.Ok(new { name = savedName, size = received });
            } catch (OperationCanceledException) {
                Status?.Invoke("Transfer interrupted. Please retry from iPhone.");
                return Results.StatusCode(499);
            } catch (IOException) {
                Status?.Invoke("Transfer failed. Check available disk space and retry.");
                return Results.Problem("Could not save the file.");
            } finally {
                try { File.Delete(temp); } catch (IOException) { }
                uploadSlots.Release();
            }
        });
        await app.StartAsync();
    }
    public static string SafeName(string value) {
        var name = value.Replace('\\', '/').Split('/').Last();
        name = new string(name.Select(c => char.IsControl(c) || "<>:\"/\\|?*".Contains(c) ? '_' : c).ToArray()).Trim().TrimEnd('.');
        if (string.IsNullOrWhiteSpace(name)) name = "file";
        // Leave room for the collision-proof prefix and Windows path limits.
        if (name.Length > 120) name = name[..100] + Path.GetExtension(name)[..Math.Min(20, Path.GetExtension(name).Length)];
        return name;
    }
    public async ValueTask DisposeAsync() {
        if (app is not null) { var current = app; app = null; await current.StopAsync(); await current.DisposeAsync(); }
    }
}
