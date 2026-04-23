FROM docker.io/library/golang:1.26.2-alpine3.22 AS builder
RUN apk add --no-cache ca-certificates tzdata

WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY main.go .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags="-s -w" -o /out/server .

# End of LTS 2028-08
FROM gcr.io/distroless/static-debian13:nonroot

COPY --from=builder /usr/share/zoneinfo /usr/share/zoneinfo
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /out/server /server

# id of nonroot
USER 65532:65532

EXPOSE 8080

ENTRYPOINT ["/server"]
