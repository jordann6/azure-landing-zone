using SloDemo;

public class SliTests
{
    [Theory]
    [InlineData("/healthz")]
    [InlineData("/readyz")]
    [InlineData("/metrics")]
    [InlineData("/HEALTHZ")]
    public void Probes_and_scrapes_do_not_count(string path) => Assert.False(Sli.Counts(path));

    [Theory]
    [InlineData("/")]
    [InlineData("/api/work")]
    [InlineData("/anything-else")]
    public void User_paths_count(string path) => Assert.True(Sli.Counts(path));

    [Theory]
    [InlineData(200, "2xx")]
    [InlineData(204, "2xx")]
    [InlineData(301, "3xx")]
    [InlineData(404, "4xx")]
    [InlineData(500, "5xx")]
    [InlineData(503, "5xx")]
    [InlineData(100, "other")]
    public void Status_codes_bucket_into_bounded_classes(int status, string expected) =>
        Assert.Equal(expected, Sli.CodeClass(status));

    [Fact]
    public void Unknown_routes_collapse_to_one_label() =>
        Assert.Equal("other", Sli.Route("/users/12345"));

    [Theory]
    [InlineData("20", 20)]
    [InlineData(" 35\n", 35)]
    [InlineData("150", 100)]
    [InlineData("-5", 0)]
    [InlineData("abc", 0)]
    [InlineData(null, 0)]
    public void Fault_percent_is_parsed_and_clamped(string? raw, int expected) =>
        Assert.Equal(expected, Sli.ParsePercent(raw));

    [Fact]
    public void Zero_percent_never_fails_and_hundred_always_fails()
    {
        Assert.False(Sli.ShouldFail(0, 0.0));
        Assert.True(Sli.ShouldFail(100, 99.999));
        Assert.True(Sli.ShouldFail(20, 19.9));
        Assert.False(Sli.ShouldFail(20, 20.0));
    }
}
