using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using LocalDrop;

static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
var root = Path.Combine(Path.GetTempPath(), "LocalDrop-test-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);
await using var server = new TransferServer(Path.Combine(root, "received"));
try {
    await server.StartAsync();
    using var client = new HttpClient { BaseAddress = new Uri("http://127.0.0.1:45872") };
    Check((await client.GetAsync("/v1/info")).StatusCode == HttpStatusCode.Unauthorized, "Unauthenticated request accepted");
    client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", server.Secret);
    Check((await client.GetAsync("/v1/info")).IsSuccessStatusCode, "Pairing failed");
    byte[] bytes = new byte[3 * 1024 * 1024 + 17];
    new Random(42).NextBytes(bytes);
    string source = Path.Combine(root, "example.bin");
    await File.WriteAllBytesAsync(source, bytes);
    var shared = server.Share(source);
    var listing = await client.GetFromJsonAsync<List<SharedFile>>("/v1/files");
    Check(listing?.Single().Id == shared.Id, "Shared file missing");
    Check(bytes.SequenceEqual(await client.GetByteArrayAsync("/v1/files/" + shared.Id)), "Download bytes differ");
    using var range = new HttpRequestMessage(HttpMethod.Get, "/v1/files/" + shared.Id);
    range.Headers.Range = new RangeHeaderValue(20, 39);
    using var ranged = await client.SendAsync(range);
    Check(ranged.StatusCode == HttpStatusCode.PartialContent, "Range unsupported");
    Check((await ranged.Content.ReadAsByteArrayAsync()).SequenceEqual(bytes.Skip(20).Take(20)), "Range bytes differ");
    for (int i = 0; i < 2; i++) {
        using var body = new ByteArrayContent(bytes);
        using var upload = await client.PostAsync("/v1/upload?name=..%2F..%2Fexample.bin", body);
        Check(upload.IsSuccessStatusCode, "Upload failed");
    }
    var received = Directory.GetFiles(server.ReceiveDirectory);
    Check(received.Length == 2, "Duplicate names overwrite files");
    foreach (var file in received) Check(bytes.SequenceEqual(await File.ReadAllBytesAsync(file)), "Upload bytes differ");
    server.Unshare(shared.Id);
    Check((await client.GetAsync("/v1/files/" + shared.Id)).StatusCode == HttpStatusCode.NotFound, "Unshared file accessible");
    Check(TransferServer.SafeName("../../a\\b?.txt") == "b_.txt", "Filename sanitization failed");
    Console.WriteLine("PASS: authentication, listing, byte integrity, ranges, unique names, traversal protection, unsharing.");
} finally {
    await server.DisposeAsync();
    Directory.Delete(root, recursive: true);
}
