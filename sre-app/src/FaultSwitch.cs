namespace SloDemo;

// Failure injection for the SLO drill. The percentage comes from a file mounted
// from the optional ConfigMap slo-demo-fault, which is deliberately not in Git:
// the drill flips it like a feature flag, and Flux does not fight the change
// because Flux does not own that object. With no ConfigMap the file is absent and
// the app serves normally. FAIL_PERCENT is the local-run fallback.
public sealed class FaultSwitch : BackgroundService
{
    private readonly string _path;
    private readonly int _fallback;
    private readonly ILogger<FaultSwitch> _log;
    private volatile int _percent;

    public FaultSwitch(IConfiguration config, ILogger<FaultSwitch> log)
    {
        _path = config["FAULT_FILE"] ?? "/etc/slo-demo-fault/fail_percent";
        _fallback = Sli.ParsePercent(config["FAIL_PERCENT"]);
        _percent = _fallback;
        _log = log;
    }

    public int Percent => _percent;

    protected override async Task ExecuteAsync(CancellationToken stop)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(2));
        do
        {
            var next = File.Exists(_path) ? Sli.ParsePercent(await File.ReadAllTextAsync(_path, stop)) : _fallback;
            if (next != _percent)
            {
                _log.LogWarning("fault switch {From}% -> {To}%", _percent, next);
                _percent = next;
                AppMetrics.FaultPercent.Set(next);
            }
        } while (await timer.WaitForNextTickAsync(stop));
    }
}
