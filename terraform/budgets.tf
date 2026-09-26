# ── FinOps: subscription budget with alerts ──────────────────────────────────
# Tag enforcement (cost_center, environment, data_classification) is handled by
# the Deny policies in policies.tf. This adds the spend guardrail: a monthly
# budget with actual and forecast alerts to the owner.

resource "azurerm_consumption_budget_subscription" "monthly" {
  name            = "budget-${var.project}-monthly"
  subscription_id = data.azurerm_subscription.current.id

  amount     = var.budget_amount
  time_grain = "Monthly"

  time_period {
    start_date = "2026-09-01T00:00:00Z"
  }

  notification {
    enabled        = true
    threshold      = 80
    operator       = "GreaterThanOrEqualTo"
    threshold_type = "Actual"
    contact_emails = [var.alert_email]
  }

  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThanOrEqualTo"
    threshold_type = "Actual"
    contact_emails = [var.alert_email]
  }

  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThanOrEqualTo"
    threshold_type = "Forecasted"
    contact_emails = [var.alert_email]
  }
}
