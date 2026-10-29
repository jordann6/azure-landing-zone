using Prometheus;

namespace SloDemo;

public static class AppMetrics
{
    public static readonly Counter Requests = Prometheus.Metrics.CreateCounter(
        "slo_demo_requests_total",
        "Requests that count toward the availability SLI, by route and status class.",
        new CounterConfiguration { LabelNames = ["route", "code_class"] });

    public static readonly Histogram Duration = Prometheus.Metrics.CreateHistogram(
        "slo_demo_request_duration_seconds",
        "Latency of requests that count toward the SLI.",
        new HistogramConfiguration
        {
            LabelNames = ["route"],
            Buckets = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5],
        });

    public static readonly Gauge FaultPercent = Prometheus.Metrics.CreateGauge(
        "slo_demo_fault_percent", "Injected failure percentage currently in effect.");

    public static readonly Gauge WriterLastAck = Prometheus.Metrics.CreateGauge(
        "slo_writer_last_ack_seq", "Highest sequence number the database acknowledged.");
}
