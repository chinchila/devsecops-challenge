package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"time"
)

type response struct {
	Service string `json:"service"`
}

func healthz(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
	fmt.Fprint(w, "ok")
}

func jsonHandler(serviceID string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(response{Service: serviceID})
	}
}

func upstreamHandler(w http.ResponseWriter, r *http.Request) {
	svc2URL := os.Getenv("SERVICE_2_URL")
	if svc2URL == "" {
		svc2URL = "http://service-2.service-2.svc.cluster.local:8080"
	}

	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get(svc2URL + "/")
	if err != nil {
		http.Error(w, fmt.Sprintf("upstream error: %v", err), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(resp.StatusCode)
	io.Copy(w, resp.Body)
}

func main() {
	service := os.Getenv("SERVICE")
	if service == "" {
		log.Fatal("SERVICE env var is required (service-1, service-2, service-3)")
	}

	jwtSecret := os.Getenv("JWT_SECRET")
	if jwtSecret == "" {
		log.Fatal("JWT_SECRET env var is required")
	}
	log.Printf("Service %s starting (JWT_SECRET configured: yes)", service)

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", healthz)

	switch service {
	case "service-1":
		mux.HandleFunc("/", jsonHandler("1"))
		mux.HandleFunc("/upstream", upstreamHandler)
	case "service-2":
		mux.HandleFunc("/", jsonHandler("2"))
	case "service-3":
		mux.HandleFunc("/", jsonHandler("3"))
	default:
		log.Fatalf("Unknown service: %s", service)
	}

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	srv := &http.Server{
		Addr:         ":" + port,
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  30 * time.Second,
	}

	log.Printf("Listening on :%s", port)
	if err := srv.ListenAndServe(); err != nil {
		log.Fatalf("server error: %v", err)
	}
}
