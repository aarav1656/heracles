# Outreach draft: gTrade and Ostium vault operators

Status: NOT SENT. For kamal to review and choose a contact channel.
To: gTrade (Gains Network) and Ostium vault / risk teams (contact channel to be chosen by kamal)
Subject: Weekend gap data on your stock and FX book

Hi [name],

I am Kamal, building Heracles on Arbitrum. I read gTrade's gUSDC book at every Friday close for the last 12 weekends and matched it to the Chainlink Monday open. The vault lost money on 7 of 12 weekends, worst was 2,035 USDC on 25 Sep. Small today, but it scales with your equity open interest.

Heracles is an onchain parametric layer: the vault declares its Friday book, pays a premium, and gets paid from the feed if Monday gaps past a retention. It can also refuse new OI the vault cannot cover.

Two quick questions:
1. Is weekend gap something your risk team tracks or caps today?
2. Would a cover layer let you raise OI caps on stocks, or is the buffer enough?

Happy to share the per-weekend data. A one-line reply either way helps a lot.

Thanks,
Kamal

Ostium variant: replace the gTrade data line with: "I know the buffer takes first loss and you hedge offchain; I am curious whether the buffer providers would want a weekend layer."
