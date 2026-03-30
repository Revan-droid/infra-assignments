package main

import (
	"log"
	"net/http"
	"os"
	"time"

	"config-service/internal/handler"
	"config-service/internal/repository"
	"config-service/internal/service"
)

func main() {
	port := os.Getenv("APP_PORT")
	if port == "" {
		port = "8080"
	}

	repo := repository.NewInMemory()
	svc := service.New(repo)
	h := handler.New(svc)

	mux := http.NewServeMux()
	h.RegisterRoutes(mux)

	srv := &http.Server{
		Addr:         ":" + port,
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	log.Printf("starting config-service on :%s", port)

	if err := srv.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}
