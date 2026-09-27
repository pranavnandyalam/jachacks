FROM golang:1.24.2-bookworm AS build
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -trimpath -o /dashboard .
RUN mkdir /data && chown 10001:10001 /data
FROM scratch
WORKDIR /app
COPY --from=build /dashboard /app/dashboard
COPY --from=build --chown=10001:10001 /data /data
COPY public /app/public
USER 10001:10001
EXPOSE 8080
CMD ["/app/dashboard"]
