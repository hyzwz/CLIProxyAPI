// Package claude provides OAuth2 authentication and quota management for Anthropic's Claude API.
package claude

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	log "github.com/sirupsen/logrus"
)

const (
	// ConsoleAPIBaseURL is the base URL for Anthropic Console API
	ConsoleAPIBaseURL = "https://console.anthropic.com/api/v1"
)

// QuotaInfo represents the quota information for a Claude account
type QuotaInfo struct {
	// Organization information
	OrganizationID   string `json:"organization_id"`
	OrganizationName string `json:"organization_name"`

	// Quota details
	MonthlyQuota     int64   `json:"monthly_quota"`      // Monthly quota in tokens
	UsedQuota        int64   `json:"used_quota"`         // Used tokens this month
	RemainingQuota   int64   `json:"remaining_quota"`    // Remaining tokens
	QuotaPercentage  float64 `json:"quota_percentage"`   // Usage percentage
	QuotaResetDate   string  `json:"quota_reset_date"`   // Next reset date
	QuotaResetTime   int64   `json:"quota_reset_time"`   // Next reset timestamp

	// Rate limit information
	RequestsLimit     int `json:"requests_limit"`      // Requests per minute
	RequestsRemaining int `json:"requests_remaining"`  // Remaining requests

	// Account tier
	PlanType string `json:"plan_type"` // e.g., "free", "pro", "team"

	// Additional metadata
	LastUpdated time.Time `json:"last_updated"`
	Email       string    `json:"email"`
}

// QuotaResponse represents the raw response from Anthropic Console API
type quotaResponse struct {
	Organization struct {
		UUID string `json:"uuid"`
		Name string `json:"name"`
	} `json:"organization"`
	Usage struct {
		MonthlyTokens     int64  `json:"monthly_tokens"`
		UsedTokens        int64  `json:"used_tokens"`
		RemainingTokens   int64  `json:"remaining_tokens"`
		NextResetDate     string `json:"next_reset_date"`
		NextResetUnixTime int64  `json:"next_reset_unix_time"`
	} `json:"usage"`
	RateLimit struct {
		RequestsPerMinute int `json:"requests_per_minute"`
		RequestsRemaining int `json:"requests_remaining"`
	} `json:"rate_limit"`
	Account struct {
		PlanType     string `json:"plan_type"`
		EmailAddress string `json:"email_address"`
	} `json:"account"`
}

// GetQuotaInfo queries the Anthropic Console API for quota information
func (o *ClaudeAuth) GetQuotaInfo(ctx context.Context, accessToken string) (*QuotaInfo, error) {
	if strings.TrimSpace(accessToken) == "" {
		return nil, fmt.Errorf("access token is required")
	}

	// Try multiple possible endpoints
	endpoints := []string{
		"/organization/usage",
		"/organization/quota",
		"/account/usage",
		"/usage",
	}

	var lastErr error
	for _, endpoint := range endpoints {
		quota, err := o.queryQuotaEndpoint(ctx, accessToken, endpoint)
		if err == nil {
			return quota, nil
		}
		lastErr = err
		log.Debugf("Failed to query %s: %v", endpoint, err)
	}

	return nil, fmt.Errorf("failed to query quota from all endpoints: %w", lastErr)
}

// queryQuotaEndpoint queries a specific Anthropic Console API endpoint
func (o *ClaudeAuth) queryQuotaEndpoint(ctx context.Context, accessToken, endpoint string) (*QuotaInfo, error) {
	url := ConsoleAPIBaseURL + endpoint

	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create quota request: %w", err)
	}

	req.Header.Set("Authorization", "Bearer "+accessToken)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	req.Header.Set("anthropic-version", "2023-06-01")

	resp, err := o.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("quota request failed: %w", err)
	}
	defer func() {
		_ = resp.Body.Close()
	}()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read quota response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		// Log response for debugging
		log.Debugf("Quota endpoint %s returned status %d: %s", endpoint, resp.StatusCode, string(body))
		return nil, fmt.Errorf("quota request failed with status %d: %s", resp.StatusCode, string(body))
	}

	// Try to parse as structured response
	var quotaResp quotaResponse
	if err = json.Unmarshal(body, &quotaResp); err != nil {
		// If structured parsing fails, try to extract useful information from raw JSON
		return parseRawQuotaResponse(body)
	}

	return convertToQuotaInfo(&quotaResp), nil
}

// convertToQuotaInfo converts the API response to QuotaInfo
func convertToQuotaInfo(resp *quotaResponse) *QuotaInfo {
	quota := &QuotaInfo{
		OrganizationID:    resp.Organization.UUID,
		OrganizationName:  resp.Organization.Name,
		MonthlyQuota:      resp.Usage.MonthlyTokens,
		UsedQuota:         resp.Usage.UsedTokens,
		RemainingQuota:    resp.Usage.RemainingTokens,
		QuotaResetDate:    resp.Usage.NextResetDate,
		QuotaResetTime:    resp.Usage.NextResetUnixTime,
		RequestsLimit:     resp.RateLimit.RequestsPerMinute,
		RequestsRemaining: resp.RateLimit.RequestsRemaining,
		PlanType:          resp.Account.PlanType,
		Email:             resp.Account.EmailAddress,
		LastUpdated:       time.Now(),
	}

	// Calculate quota percentage
	if quota.MonthlyQuota > 0 {
		quota.QuotaPercentage = float64(quota.UsedQuota) / float64(quota.MonthlyQuota) * 100
	}

	return quota
}

// parseRawQuotaResponse attempts to extract quota info from raw JSON response
func parseRawQuotaResponse(body []byte) (*QuotaInfo, error) {
	// This is a fallback parser for cases where the API structure differs
	var raw map[string]interface{}
	if err := json.Unmarshal(body, &raw); err != nil {
		return nil, fmt.Errorf("failed to parse raw quota response: %w", err)
	}

	quota := &QuotaInfo{
		LastUpdated: time.Now(),
	}

	// Try to extract common fields using reflection or type assertions
	if org, ok := raw["organization"].(map[string]interface{}); ok {
		if uuid, ok := org["uuid"].(string); ok {
			quota.OrganizationID = uuid
		}
		if name, ok := org["name"].(string); ok {
			quota.OrganizationName = name
		}
	}

	if usage, ok := raw["usage"].(map[string]interface{}); ok {
		if monthly, ok := usage["monthly_tokens"].(float64); ok {
			quota.MonthlyQuota = int64(monthly)
		}
		if used, ok := usage["used_tokens"].(float64); ok {
			quota.UsedQuota = int64(used)
		}
		if remaining, ok := usage["remaining_tokens"].(float64); ok {
			quota.RemainingQuota = int64(remaining)
		}
	}

	// Calculate remaining if not provided
	if quota.RemainingQuota == 0 && quota.MonthlyQuota > 0 && quota.UsedQuota > 0 {
		quota.RemainingQuota = quota.MonthlyQuota - quota.UsedQuota
	}

	// Calculate percentage
	if quota.MonthlyQuota > 0 {
		quota.QuotaPercentage = float64(quota.UsedQuota) / float64(quota.MonthlyQuota) * 100
	}

	return quota, nil
}

// GetQuotaFromStorage retrieves quota information using stored credentials
func GetQuotaFromStorage(ctx context.Context, storage *ClaudeTokenStorage) (*QuotaInfo, error) {
	if storage == nil {
		return nil, fmt.Errorf("token storage is nil")
	}

	accessToken := strings.TrimSpace(storage.AccessToken)
	if accessToken == "" {
		return nil, fmt.Errorf("access token is empty")
	}

	// Create a new ClaudeAuth instance with default config
	auth := &ClaudeAuth{
		httpClient: NewAnthropicHttpClient(nil),
	}

	quota, err := auth.GetQuotaInfo(ctx, accessToken)
	if err != nil {
		return nil, fmt.Errorf("failed to get quota info: %w", err)
	}

	// Add email from storage if not present in quota
	if quota.Email == "" && storage.Email != "" {
		quota.Email = storage.Email
	}

	return quota, nil
}
