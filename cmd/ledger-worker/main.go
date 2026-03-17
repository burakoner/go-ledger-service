package main

import (
	"log"
	"os"
)

// main prints runtime environment values for quick verification and exits.
func main() {
	log.Printf("Ledger worker env check started.")
	log.Printf("DATABASE_URL=%q", os.Getenv("DATABASE_URL"))
	log.Printf("REDIS_ADDR=%q", os.Getenv("REDIS_ADDR"))
	log.Printf("RABBITMQ_URL=%q", os.Getenv("RABBITMQ_URL"))
	log.Printf("RABBITMQ_USER=%q", os.Getenv("RABBITMQ_USER"))
	log.Printf("RABBITMQ_PASSWORD=%q", os.Getenv("RABBITMQ_PASSWORD"))
	log.Printf("Ledger worker env check completed. Exiting.")
}
