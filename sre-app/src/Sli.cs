namespace SloDemo;

// Pure rules the SLI depends on, kept apart from the web host so they are unit
// tested: which requests count, how a status code is bucketed, and when the
// fault switch fails a request.
public static class Sli
{
    // Probes and scrapes are not user traffic. Counting them would pad the good
    // side of the ratio and hide a real outage behind healthy health checks.
    private static readonly HashSet<string> Excluded = new(StringComparer.OrdinalIgnoreCase)
    {
        "/healthz", "/readyz", "/metrics",
    };

    public static bool Counts(string path) => !Excluded.Contains(path);

    // Bounded label values: one series per class, never one per status code or
    // per URL, so cardinality stays fixed whatever the traffic looks like.
    public static string CodeClass(int status) => status switch
    {
        >= 500 => "5xx",
        >= 400 => "4xx",
        >= 300 => "3xx",
        >= 200 => "2xx",
        _ => "other",
    };

    // Routes the app serves; anything else is reported as "other" for the same
    // cardinality reason.
    public static string Route(string path) => path switch
    {
        "/" => "/",
        "/api/work" => "/api/work",
        _ => "other",
    };

    public static int ParsePercent(string? raw)
    {
        if (!int.TryParse(raw?.Trim(), out var value)) return 0;
        return Math.Clamp(value, 0, 100);
    }

    // roll is uniform in [0, 100).
    public static bool ShouldFail(int failPercent, double roll) => roll < failPercent;
}
