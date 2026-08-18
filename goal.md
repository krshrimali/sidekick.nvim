The current UI for sidekick review is floating, which is bad. I want it to be dedicated buffer, like how we have in ~/Documents/diffview.nvim.

I dont' want it to confuse b/w the keymaps of neovim as well, so ensure it's like a new tab buffer altogether where I can review. Additionally, the UI/UX for viewing my own comments that I've added should be very easy and you should show common keymaps on the UI itself as a hint to press for common operations.

Additionally, see if you can render the output responses in proper format as well, right now -- all of it is very noisy. We care about the final response, and files changed separately only (for review).

Ensure by the time you're done, it's the smoothest experience ever, and do proper UI testing using neovim's UI testing (via headless mode etc.) --- take screenshots and understand yourself on how it's going. Compare with before & after before you call it done.
