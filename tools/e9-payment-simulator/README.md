# E9 local payment simulator

Standalone local demo; not an official KBZPay sandbox or integration.
No provider connection, real money transfer or Gym Pro ledger writes.
QR codes contain demo identifiers and cannot accept payments.
Orders, events and sessions exist only in memory.

Verification:
- 24 automated checks passed with the installed QR package.
- Browser history showed succeeded, failed and cancelled orders.
- Simulator shutdown and memory cleanup confirmed.
- Browser replay receipt comparison was not separately confirmed.

Start from the project root:
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\e9-start-local-payment-demo.ps1

Real KBZPay integration remains pending provider documentation and sandbox access.
