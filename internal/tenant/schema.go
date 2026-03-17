package tenant

import "regexp"

var schemaNamePattern = regexp.MustCompile(`^[a-zA-Z_][a-zA-Z0-9_]*$`)

// IsValidSchemaName validates PostgreSQL schema identifier format.
func IsValidSchemaName(schemaName string) bool {
	return schemaNamePattern.MatchString(schemaName)
}

