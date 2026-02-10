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
	// ClaudeAIAPIBaseURL is the base URL for Claude.ai API (for OAuth accounts)
	ClaudeAIAPIBaseURL = "https://claude.ai/api"
	// ConsoleAPIBaseURL is the base URL for Anthropic Console API (for API keys)
	ConsoleAPIBaseURL = "https://console.anthropic.com/api/v1"
)

// QuotaInfo represents the quota information for a Claude account
type QuotaInfo struct {
	// Organization information
	OrganizationID   string `json:"organization_id"`
	OrganizationName string `json:"organization_name"`

	// Quota details (for API key accounts with absolute quotas)
	MonthlyQuota     int64   `json:"monthly_quota"`      // Monthly quota in tokens
	UsedQuota        int64   `json:"used_quota"`         // Used tokens this month
	RemainingQuota   int64   `json:"remaining_quota"`    // Remaining tokens
	QuotaPercentage  float64 `json:"quota_percentage"`   // Usage percentage
	QuotaResetDate   string  `json:"quota_reset_date"`   // Next reset date
	QuotaResetTime   int64   `json:"quota_reset_time"`   // Next reset timestamp

	// OAuth rolling window usage (for OAuth accounts)
	FiveHourUtilization  float64 `json:"five_hour_utilization"`   // 5-hour window usage (0-100%)
	FiveHourResetsAt     string  `json:"five_hour_resets_at"`     // 5-hour window reset time
	SevenDayUtilization  float64 `json:"seven_day_utilization"`   // 7-day window usage (0-100%)
	SevenDayResetsAt     string  `json:"seven_day_resets_at"`     // 7-day window reset time
	SevenDaySonnetUtil   float64 `json:"seven_day_sonnet_util"`   // 7-day Sonnet usage (0-100%)
	SevenDaySonnetResets string  `json:"seven_day_sonnet_resets"` // 7-day Sonnet reset time

	// Rate limit information
	RequestsLimit     int `json:"requests_limit"`      // Requests per minute
	RequestsRemaining int `json:"requests_remaining"`  // Remaining requests

	// Account tier
	PlanType string `json:"plan_type"` // e.g., "free", "pro", "team", "oauth"

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

// GetQuotaInfo queries the Anthropic OAuth Usage API for quota information
func (o *ClaudeAuth) GetQuotaInfo(ctx context.Context, accessToken string) (*QuotaInfo, error) {
	if strings.TrimSpace(accessToken) == "" {
		return nil, fmt.Errorf("access token is required")
	}

	// Use api.anthropic.com/api/oauth/usage endpoint (correct endpoint for OAuth usage stats)
	return o.queryOAuthUsage(ctx, accessToken)
}

// queryOAuthUsage queries api.anthropic.com/api/oauth/usage for detailed usage statistics
func (o *ClaudeAuth) queryOAuthUsage(ctx context.Context, accessToken string) (*QuotaInfo, error) {
	url := "https://api.anthropic.com/api/oauth/usage"

	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}

	// Set required headers for OAuth usage API
	req.Header.Set("Authorization", fmt.Sprintf("Bearer %s", accessToken))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	req.Header.Set("anthropic-beta", "oauth-2025-04-20") // Required beta header
	req.Header.Set("User-Agent", "claude-cli/2.0.53 (external, cli)")
	req.Header.Set("Accept-Language", "en-US,en;q=0.9")

	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("request failed: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		log.Debugf("OAuth usage API returned status %d: %s", resp.StatusCode, string(body))

		if resp.StatusCode == http.StatusForbidden {
			return nil, fmt.Errorf("access forbidden - this account may use Setup Token instead of OAuth")
		}

		if resp.StatusCode == http.StatusUnauthorized {
			return nil, fmt.Errorf("authentication failed - token may be invalid or expired")
		}

		return nil, fmt.Errorf("API returned status %d: %s", resp.StatusCode, string(body))
	}

	// Parse OAuth usage response
	var usageData struct {
		FiveHour struct {
			Utilization float64 `json:"utilization"`
			ResetsAt    string  `json:"resets_at"`
		} `json:"five_hour"`
		SevenDay struct {
			Utilization float64 `json:"utilization"`
			ResetsAt    string  `json:"resets_at"`
		} `json:"seven_day"`
		SevenDaySonnet struct {
			Utilization float64 `json:"utilization"`
			ResetsAt    string  `json:"resets_at"`
		} `json:"seven_day_sonnet"`
	}

	if err := json.Unmarshal(body, &usageData); err != nil {
		return nil, fmt.Errorf("failed to parse response: %w", err)
	}

	// Build QuotaInfo from usage data
	quotaInfo := &QuotaInfo{
		LastUpdated: time.Now(),
		PlanType:    "oauth", // OAuth account type
	}

	// Store OAuth rolling window usage data
	// Utilization is a percentage (0-1), convert to 0-100 range
	quotaInfo.FiveHourUtilization = usageData.FiveHour.Utilization * 100
	quotaInfo.FiveHourResetsAt = usageData.FiveHour.ResetsAt

	quotaInfo.SevenDayUtilization = usageData.SevenDay.Utilization * 100
	quotaInfo.SevenDayResetsAt = usageData.SevenDay.ResetsAt

	quotaInfo.SevenDaySonnetUtil = usageData.SevenDaySonnet.Utilization * 100
	quotaInfo.SevenDaySonnetResets = usageData.SevenDaySonnet.ResetsAt

	// For backward compatibility with UI expecting monthly quota:
	// Use 5-hour utilization as the primary percentage
	quotaInfo.QuotaPercentage = quotaInfo.FiveHourUtilization
	quotaInfo.QuotaResetDate = usageData.FiveHour.ResetsAt

	// Parse reset time
	if usageData.FiveHour.ResetsAt != "" {
		if resetTime, err := time.Parse(time.RFC3339, usageData.FiveHour.ResetsAt); err == nil {
			quotaInfo.QuotaResetTime = resetTime.Unix()
		}
	}

	log.Debugf("Successfully retrieved OAuth usage: 5h=%.1f%%, 7d=%.1f%%, 7d-sonnet=%.1f%%",
		quotaInfo.FiveHourUtilization, quotaInfo.SevenDayUtilization, quotaInfo.SevenDaySonnetUtil)

	return quotaInfo, nil
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

		// Provide user-friendly error message for common cases
		if resp.StatusCode == http.StatusNotFound {
			return nil, fmt.Errorf("quota API endpoint not found - this account may not have access to organization quota information (individual/free accounts don't support quota queries)")
		}
		if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
			return nil, fmt.Errorf("access denied - this OAuth token may not have permission to view quota information")
		}

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
