using System.Diagnostics;
using System.Text.Json;
using Npgsql;
using Prometheus;
using SloDemo;

// One image, three roles, chosen by MODE:
//   api      the service the SLO is about (port 8080, metrics on 9090)
//   loadgen  steady synthetic traffic against the api, so the SLI always has a
//            denominator
//   writer   one sequenced insert per second into Postgres, logging each
//            acknowledged write, so the restore drill can measure lost writes
var mode = (Environment.GetEnvironmentVariable("MODE") ?? "api").ToLowerInvariant();

// Metrics live on their own port in every mode, so scrapes never touch the
// request path the SLI measures.
using var metricServer = new KestrelMetricServer(port: 9090);
metricServer.Start();

switch (mode)
{
    case "api":
        await RunApi(args);
        break;
    case "loadgen":
        await RunLoadgen();
        break;
    case "writer":
        await RunWriter();
        break;
    default:
        Console.Error.WriteLine($"unknown MODE '{mode}' (api, loadgen, writer)");
        return 2;
}
return 0;

static async Task RunApi(string[] args)
{
    var builder = WebApplication.CreateBuilder(args);
    builder.WebHost.UseUrls($"http://0.0.0.0:{Environment.GetEnvironmentVariable("PORT") ?? "8080"}");
    builder.Services.AddSingleton<FaultSwitch>();
    builder.Services.AddHostedService(sp => sp.GetRequiredService<FaultSwitch>());
    var app = builder.Build();

    var ready = true;
    app.Lifetime.ApplicationStopping.Register(() => ready = false);

    // Count and time every request the SLI covers, after the response status is
    // final, including the 503s the fault switch produces.
    app.Use(async (ctx, next) =>
    {
        var path = ctx.Request.Path.Value ?? "/";
        if (!Sli.Counts(path))
        {
            await next();
            return;
        }
        var route = Sli.Route(path);
        var timer = Stopwatch.StartNew();
        try
        {
            await next();
        }
        catch
        {
            ctx.Response.StatusCode = 500;
            throw;
        }
        finally
        {
            AppMetrics.Duration.WithLabels(route).Observe(timer.Elapsed.TotalSeconds);
            AppMetrics.Requests.WithLabels(route, Sli.CodeClass(ctx.Response.StatusCode)).Inc();
        }
    });

    var faults = app.Services.GetRequiredService<FaultSwitch>();

    async Task<IResult> Work()
    {
        // Small, variable latency so the p95 panel has a shape.
        await Task.Delay(Random.Shared.Next(5, 40));
        if (Sli.ShouldFail(faults.Percent, Random.Shared.NextDouble() * 100))
            return Results.StatusCode(StatusCodes.Status503ServiceUnavailable);
        return Results.Ok(new { ok = true, host = Environment.MachineName });
    }

    app.MapGet("/", Work);
    app.MapGet("/api/work", Work);
    app.MapGet("/healthz", () => Results.Ok("ok"));
    app.MapGet("/readyz", () => ready ? Results.Ok("ready") : Results.StatusCode(503));

    await app.RunAsync();
}

static async Task RunLoadgen()
{
    var target = Environment.GetEnvironmentVariable("TARGET_URL") ?? "http://slo-demo.slo-demo.svc.cluster.local/api/work";
    var rps = Math.Max(1, int.TryParse(Environment.GetEnvironmentVariable("RPS"), out var r) ? r : 20);
    using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(5) };
    using var stop = StopOnSignal();
    var sent = 0L;
    var failed = 0L;
    var report = Stopwatch.StartNew();
    using var timer = new PeriodicTimer(TimeSpan.FromSeconds(1.0 / rps));

    Console.WriteLine($"loadgen: {rps} rps against {target}");
    try
    {
        while (await timer.WaitForNextTickAsync(stop.Token))
        {
            // Fire and forget, so a slow response does not lower the offered rate.
            _ = Task.Run(async () =>
            {
                try
                {
                    using var resp = await http.GetAsync(target, stop.Token);
                    if ((int)resp.StatusCode >= 500) Interlocked.Increment(ref failed);
                }
                catch (Exception) when (!stop.IsCancellationRequested)
                {
                    Interlocked.Increment(ref failed);
                }
                Interlocked.Increment(ref sent);
            });
            if (report.Elapsed >= TimeSpan.FromSeconds(30))
            {
                Console.WriteLine(JsonSerializer.Serialize(new { evt = "loadgen", sent = Interlocked.Read(ref sent), failed = Interlocked.Read(ref failed) }));
                report.Restart();
            }
        }
    }
    catch (OperationCanceledException)
    {
    }
}

static async Task RunWriter()
{
    var password = (await File.ReadAllTextAsync(Environment.GetEnvironmentVariable("DB_PASSWORD_FILE") ?? "/mnt/secrets/slo-data-db-password")).Trim();
    var conn = new NpgsqlConnectionStringBuilder
    {
        Host = Environment.GetEnvironmentVariable("DB_HOST") ?? "postgres",
        Database = Environment.GetEnvironmentVariable("DB_NAME") ?? "slo",
        Username = Environment.GetEnvironmentVariable("DB_USER") ?? "slo",
        Password = password,
        Timeout = 5,
        CommandTimeout = 5,
    }.ConnectionString;
    using var stop = StopOnSignal();
    long lastAck = 0;

    await using var source = NpgsqlDataSource.Create(conn);
    while (!stop.IsCancellationRequested)
    {
        try
        {
            await using (var cmd = source.CreateCommand(
                "CREATE TABLE IF NOT EXISTS writes (seq bigint PRIMARY KEY, written_at timestamptz NOT NULL DEFAULT now())"))
                await cmd.ExecuteNonQueryAsync(stop.Token);
            await using (var cmd = source.CreateCommand("SELECT COALESCE(max(seq), 0) FROM writes"))
                lastAck = (long)(await cmd.ExecuteScalarAsync(stop.Token))!;
            Log("resume", lastAck);
            break;
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            Console.WriteLine(JsonSerializer.Serialize(new { evt = "connect_error", error = e.Message }));
            await Task.Delay(TimeSpan.FromSeconds(2), stop.Token).ContinueWith(_ => { });
        }
    }

    using var timer = new PeriodicTimer(TimeSpan.FromSeconds(1));
    try
    {
        while (await timer.WaitForNextTickAsync(stop.Token))
        {
            var next = lastAck + 1;
            try
            {
                // Autocommit with synchronous_commit on (the Postgres default):
                // the insert returns only after the WAL record is flushed, so an
                // "ack" line is a durable write.
                await using var cmd = source.CreateCommand("INSERT INTO writes (seq) VALUES ($1) RETURNING written_at");
                cmd.Parameters.AddWithValue(next);
                var at = (DateTime)(await cmd.ExecuteScalarAsync(stop.Token))!;
                lastAck = next;
                AppMetrics.WriterLastAck.Set(lastAck);
                Log("ack", lastAck, at);
            }
            catch (Exception e) when (e is not OperationCanceledException)
            {
                Console.WriteLine(JsonSerializer.Serialize(new { evt = "write_error", seq = next, error = e.Message }));
            }
        }
    }
    catch (OperationCanceledException)
    {
    }
    Log("stop", lastAck);

    static void Log(string evt, long seq, DateTime? at = null) =>
        Console.WriteLine(JsonSerializer.Serialize(new { evt, seq, server_ts = at?.ToUniversalTime().ToString("O"), ts = DateTime.UtcNow.ToString("O") }));
}

static CancellationTokenSource StopOnSignal()
{
    // Handle SIGTERM and SIGINT instead of letting the runtime exit, so the loop
    // finishes its current write and the final "stop" line (the last acknowledged
    // sequence) is always logged before the pod goes away.
    var cts = new CancellationTokenSource();
    foreach (var signal in new[] { System.Runtime.InteropServices.PosixSignal.SIGTERM, System.Runtime.InteropServices.PosixSignal.SIGINT })
    {
        Registrations.Add(System.Runtime.InteropServices.PosixSignalRegistration.Create(signal, ctx =>
        {
            ctx.Cancel = true;
            cts.Cancel();
        }));
    }
    return cts;
}

static partial class Program
{
    // Keeps signal registrations alive for the life of the process.
    internal static readonly List<IDisposable> Registrations = [];
}
