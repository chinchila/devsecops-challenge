FROM docker.io/library/python:3.9

WORKDIR /app

COPY main.go .

EXPOSE 8080

CMD ["python3", "-c", "import http.server; http.server.test()"]
