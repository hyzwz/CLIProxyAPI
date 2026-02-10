package claude

import (
	"context"
	"testing"
	"time"
)

func TestQuotaInfo(t *testing.T) {
	// Test QuotaInfo struct initialization
	quota := &QuotaInfo{
		MonthlyQuota:   1000000,
		UsedQuota:      250000,
		RemainingQuota: 750000,
		LastUpdated:    time.Now(),
	}

	if quota.MonthlyQuota != 1000000 {
		t.Errorf("Expected monthly quota 1000000, got %d", quota.MonthlyQuota)
	}

	// Test quota percentage calculation
	expectedPercentage := 25.0
	calculatedPercentage := float64(quota.UsedQuota) / float64(quota.MonthlyQuota) * 100
	if calculatedPercentage != expectedPercentage {
		t.Errorf("Expected percentage %.2f%%, got %.2f%%", expectedPercentage, calculatedPercentage)
	}
}

func TestConvertToQuotaInfo(t *testing.T) {
	resp := &quotaResponse{
		Organization: struct {
			UUID string `json:"uuid"`
			Name string `json:"name"`
		}{
			UUID: "test-org-uuid",
			Name: "Test Organization",
		},
		Usage: struct {
			MonthlyTokens     int64  `json:"monthly_tokens"`
			UsedTokens        int64  `json:"used_tokens"`
			RemainingTokens   int64  `json:"remaining_tokens"`
			NextResetDate     string `json:"next_reset_date"`
			NextResetUnixTime int64  `json:"next_reset_unix_time"`
		}{
			MonthlyTokens:     1000000,
			UsedTokens:        250000,
			RemainingTokens:   750000,
			NextResetDate:     "2026-03-01T00:00:00Z",
			NextResetUnixTime: 1740787200,
		},
		RateLimit: struct {
			RequestsPerMinute int `json:"requests_per_minute"`
			RequestsRemaining int `json:"requests_remaining"`
		}{
			RequestsPerMinute: 50,
			RequestsRemaining: 45,
		},
		Account: struct {
			PlanType     string `json:"plan_type"`
			EmailAddress string `json:"email_address"`
		}{
			PlanType:     "pro",
			EmailAddress: "test@example.com",
		},
	}

	quota := convertToQuotaInfo(resp)

	if quota.OrganizationID != "test-org-uuid" {
		t.Errorf("Expected organization ID 'test-org-uuid', got '%s'", quota.OrganizationID)
	}

	if quota.MonthlyQuota != 1000000 {
		t.Errorf("Expected monthly quota 1000000, got %d", quota.MonthlyQuota)
	}

	if quota.UsedQuota != 250000 {
		t.Errorf("Expected used quota 250000, got %d", quota.UsedQuota)
	}

	if quota.RemainingQuota != 750000 {
		t.Errorf("Expected remaining quota 750000, got %d", quota.RemainingQuota)
	}

	expectedPercentage := 25.0
	if quota.QuotaPercentage != expectedPercentage {
		t.Errorf("Expected percentage %.2f%%, got %.2f%%", expectedPercentage, quota.QuotaPercentage)
	}

	if quota.PlanType != "pro" {
		t.Errorf("Expected plan type 'pro', got '%s'", quota.PlanType)
	}

	if quota.Email != "test@example.com" {
		t.Errorf("Expected email 'test@example.com', got '%s'", quota.Email)
	}
}

func TestParseRawQuotaResponse(t *testing.T) {
	rawJSON := []byte(`{
		"organization": {
			"uuid": "test-org-uuid",
			"name": "Test Organization"
		},
		"usage": {
			"monthly_tokens": 1000000,
			"used_tokens": 250000,
			"remaining_tokens": 750000
		}
	}`)

	quota, err := parseRawQuotaResponse(rawJSON)
	if err != nil {
		t.Fatalf("Failed to parse raw quota response: %v", err)
	}

	if quota.OrganizationID != "test-org-uuid" {
		t.Errorf("Expected organization ID 'test-org-uuid', got '%s'", quota.OrganizationID)
	}

	if quota.MonthlyQuota != 1000000 {
		t.Errorf("Expected monthly quota 1000000, got %d", quota.MonthlyQuota)
	}

	expectedPercentage := 25.0
	if quota.QuotaPercentage != expectedPercentage {
		t.Errorf("Expected percentage %.2f%%, got %.2f%%", expectedPercentage, quota.QuotaPercentage)
	}
}

func TestGetQuotaFromStorage_NilStorage(t *testing.T) {
	ctx := context.Background()
	_, err := GetQuotaFromStorage(ctx, nil)
	if err == nil {
		t.Error("Expected error for nil storage, got nil")
	}
}

func TestGetQuotaFromStorage_EmptyToken(t *testing.T) {
	ctx := context.Background()
	storage := &ClaudeTokenStorage{
		AccessToken: "",
	}
	_, err := GetQuotaFromStorage(ctx, storage)
	if err == nil {
		t.Error("Expected error for empty access token, got nil")
	}
}
