# Multi-arch (amd64 for AKS, arm64 for a local k3d site) without emulation: the
# SDK stage runs on the build host's architecture and cross-publishes for the
# target, then lands on the chiseled runtime image (no shell, no package
# manager, non-root by default).
FROM --platform=$BUILDPLATFORM mcr.microsoft.com/dotnet/sdk:10.0 AS build
ARG TARGETARCH
WORKDIR /src
COPY src/SloDemo.csproj src/
RUN dotnet restore src/SloDemo.csproj -a "$TARGETARCH"
COPY src/ src/
RUN dotnet publish src/SloDemo.csproj -c Release -a "$TARGETARCH" --no-restore -o /out /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:10.0-noble-chiseled
WORKDIR /app
COPY --from=build /out .
EXPOSE 8080 9090
ENTRYPOINT ["dotnet", "SloDemo.dll"]
