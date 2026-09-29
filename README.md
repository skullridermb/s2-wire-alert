# S2 Wire alert

Checks the S2 Underground "The Wire" podcast feed every 10 minutes via GitHub Actions and sends an ntfy push notification when a new episode is marked Priority, Urgent or Flash.

The ntfy topic is stored in the `NTFY_TOPIC` repository secret.
