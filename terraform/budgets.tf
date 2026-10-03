# ── FinOps: subscription budget with alerts ──────────────────────────────────
# Tag enforcement (cost_center, environment, data_classification) is handled by
# the Deny policies in policies.tf. This adds the spend guardrail: a monthly
# budget with actual and forecast alerts to the owner.

resource "azurerm_consumption_budget_subscription" "monthly" {
  name            = "budget-${var.project}-monthly"
  subscription_id = data.azurerm_subscription.current.id

  amount     = var.budget_amount
  time_grain = "Monthly"

  # Azure rejects a monthly budget whose start date is before the current month,
  # so a hardcoded date breaks the first time the stack is redeployed in a later
  # month. Start on the first of the month the apply runs in, and ignore the
  # drift afterwards so the budget is not recreated every plan.
  time_period {
    start_date = formatdate("YYYY-MM-01'T'00:00:00Z", timestamp())
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

  lifecycle {
    ignore_changes = [time_period]
  }
}
