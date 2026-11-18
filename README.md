# ProfitCrafter Forever Plus

An extended build of ProfitCrafter Forever 0.3.0 by MostlyNotBroken, for World of Warcraft: Forever. It is shared with the original developer for possible integration.

The first commit is the unmodified 0.3.0 release, so diffing against it shows every change. Below is everything that is new or fixed compared with 0.3.0.

To install, put the folder in `_forever_/Interface/AddOns/` and name it `ProfitCrafterForever`.

## New

### Profit

- Every recipe has a separate Auction Profit and Vendor Profit. They replace the single Profit column and appear in the tables, tooltips, Make me gold, sale notes, the Purge list and "Now profitable" alerts.
- New Sells at vendor column, next to Sells at auction.
- Profit % shows the higher of the auction and vendor percentages, and the recipe tooltip says which.
- "Only profitable" is replaced by a Minimum profit % box on the Recipes and Learn pages, 10% by default. The tables always hide recipes that make less than it both at auction and at a vendor. Skill up and Gear upgrades plans ignore it.
- New Craftable at Profit, Total Auction Profit and Total Vendor Profit columns. Craftable at Profit counts the crafts that make your minimum profit, at auction or at a vendor, whichever gives more. They price the whole batch against the real listings, not just the cheapest one, and allow for your gold, what is listed, your bag space and auction deposits.
- The "how many?" pop-up and the Crafting plan price batches the same way and show both profits. The pop-up has a Max profitable button and says where buying will stop.
- Best bets only shows recipes that make the minimum profit. A recipe sold at auction also has to have sold today, at least half as many as are listed. Hot sellers, with more sold today than listed, come first, then the rest by profit.
- Make me gold uses the same rules for its picks and its Your materials list, and shows both profits on every line and in the totals.
- Have materials only plans recipes that make the minimum profit, and auction recipes only if they sold today.
- New setting to only recommend auction recipes that sold today, on by default. A recipe with no sales today shows an orange 0 and a note in its tooltip.
- Auction flips fill every column, are labelled as flips and have a fuller tooltip.

### Buying

- Buying stops before a material would take its recipe below the minimum profit. The plan is then cut to what was bought and chat says so. `/pc undo` puts it back.
- A material several recipes share goes to the ones that can afford it most, and what you already have covers those first.
- Recipes whose rare materials you already have are still finished, as long as each one earns more than its other materials cost.
- One-click buying, on by default. Buy asks for the price and buys straight away if the item is still profitable. If the game won't allow it, it goes back to two clicks.
- Quick Buy, the coin on each recipe. It plans as many crafts as make your minimum profit, buys the main auction material and opens the plan.
- An auction price more than 5% above what the listings showed is refused and the listings are read again. 0.3.0 only warned, at 25%.
- A price that has been waiting for over 10 seconds is checked again before buying.
- Every auction purchase ends with a clear message, including the odd cases: paid but no answer, an answer but no gold taken, failed but gold taken, and a purchase that went through late.
- Auction listings are bought whenever they are cheaper than a vendor (0.3.0 needed them 10% cheaper). If the price comes back at or above the vendor's, the item switches to the vendor.
- Separate auctions never buy a listing bigger than the plan still needs.
- Vendor buying buys as many as your gold allows and then says it ran out. 0.3.0 refused the whole lot.
- In the Materials table, Have shows what is in the bank, in the mail and on its way. A purchase on its way shows "buying N" and its button can't be clicked again. The Buy tooltip says how many were left out to keep the minimum profit.
- The Task Button shows "Waiting for the Auction House to confirm..." while a purchase is unanswered, vendor buying progress, and "Stopped buying X (under 10% profit)".

### Selling

- Selling to a vendor sells exact amounts, splitting stacks when needed. This covers crafted items, flips, spare materials, leftovers and the Purge.
- Each vendor sale is checked before the next one, and anything left unsold is reported with the reason. At a vendor, buying finishes before selling starts, with one note at the end.
- The Sell page has Auction Profit and Vendor Profit columns.
- Junk is left to Scrap when Scrap is installed.

### Scanning and prices

- Scans also price what learnable recipes make and use.
- On the Learn page, profits built on prices over 6 hours old are marked ~, and recipes with no known source or cost show ? instead of a profit.
- Your own scan of an item beats prices shared by other players for a minute.

### Bank

- New "Use what's in my bank" setting, on by default. Turned off, the bank is ignored completely: nothing in it is counted, taken out or stored.

### Tables and tooltips

- Clicking a recipe while the Auction House is open searches for it there. 0.3.0 needed Shift held.
- Every table sorts on every column and remembers its sort. Each column has a two-line heading with a tooltip.
- Columns are sized to fit their headings and values, and the name column gets the rest. Table text is slightly smaller, and the window is wider.
- Money in a table is never cut off. The text shrinks, then the copper is dropped, then the silver.
- Recipe tooltips list every ingredient with its price, where it comes from and how many you have. They also show what a vendor pays, both profits (with the reason when one is missing), how many you can craft at a profit, what limits it, and how many make your minimum.
- The recipe count says how many recipes the minimum profit is hiding.
- Craft tasks give the item count when a recipe makes more than one, e.g. "34 Seasoned Wolf Kabob (makes 102)".
- The flight line is back, with a setting to turn it off. It hides while another flight timer is showing, such as EllesmereUI's flight bar.

## Fixed

### Buying

- Buying could go over the plan when the Auction House answered slowly. A purchase with no answer after 10 to 15 seconds was dropped and could be bought again, and cancelling forgot a purchase already sent.
- One purchase could print two or three "Bought" lines.
- Clicking Buy on a second item before the first item's price arrived could take the first item's price for the second.
- A refused purchase could later be counted as bought when gold was spent on something else.
- When the game blocked an automatic price request, it wrongly said the Auction House sent no price. It now asks for a click.
- If the Auction House changed a price you were holding, the confirm click paid the new price unchecked.
- Vendor purchases not in your bags within a second were bought again, up to three times.
- Vendor buying ignored plan changes made at the vendor, and kept offering items already bought.
- The plan priced large auction buys up the listings past what a vendor charges, instead of buying the rest from the vendor.
- Make me gold multiplied the cheapest price by the count while the cost climbed the listings. It overstated profit and could pick batches that lose money.
- Stored live listings were used indefinitely, even after the item sold out or its price changed.

### Selling

- Vendor sales only sold whole stacks. Extras and the rest of spare materials were left unsold and forgotten.
- Selling back leftovers could leave a split stack on the cursor when the only empty slot was in a profession bag.
- During a Purge, unticked items could still be sold below cost, or drop out of the tick list.
- An error while building the Purge list wiped your unticked items and could leave Purge on.
- Posting on the newer Auction House could ask for more than you had while a stack was locked.

### Bags and crafting

- The plan's bag check ignored free slots in the reagent bag.
- Vendor purchases and crafts came in smaller batches than your bags allowed, because the room freed by used-up materials wasn't counted.
- The bank crashed with a stack overflow whenever an item was on the cursor.

### Routes

- Hearthstone and teleports were offered for stops in your own zone, including jumping out and walking back in.
- The task list said "walk to X (3 yd)" for a stop you were already at, and measured later stops from where you stood instead of from the stop before.

### Interface

- A plan count typed while the rows moved could land on another recipe. Escape now cancels.
- A Keep number typed on the Sell page could land on another item.
- The empty recipe list blamed "Only profitable" when Can afford had hidden the rows.
- The "Stock up" alert always said "usually n/a".

### Data

- Unreadable (secret) game messages caused errors in the bank, mail, loot, vendor and auction messages, learned recipes and disenchanting.
- Place, NPC and recipe names shared from clients in other languages showed in another alphabet. They are now translated or left out.
- Shared prices from a player whose clock ran fast blocked newer prices until that time passed.
- On newer clients, recipes read from the profession window lost their required materials, so Learn page profits came out too high.
- Trainer windows were never read on WoW Forever, so a trainer recipe with no named trainer sent you to the nearest trainer of that profession, whether or not it teaches it. Trainer windows are now read, and a trainer you've visited is only suggested for what its window lists. A recipe the data lists only outside the cities is no longer swapped for a city trainer.
- Goldthorn Tea is taught by Henry Stern in Razorfen Downs, and Smoked Desert Dumplings comes from the quest Sharing the Knowledge in Silithus. Both pointed to the city cooking trainers.
- The crafting station check errored on clients without C_TradeSkillUI, and the undercut check errored on clients without C_AuctionHouse when Auctionator was installed.

## Performance

- Faster auction scans. Each search asks for 100 items (was 25), results are read as soon as they are complete, live listings are read back to back, and listings that haven't changed in the last 2 hours aren't read again.
- Much less work on each refresh. Your sales and purchases are indexed, bag slots and item info are read once, and sorting, searching and filtering no longer re-analyse every recipe. Tooltips are built when you hover.
- The Learn list, route planning and nearest-place lookups do far less work. Routes keep their fixed part between uses and only search the current continent.
- The direction arrows work out their aim once per tick and not at all while you stand still.
- Scrolling the task list reuses the Task Button's step, and a guide change updates both in one pass.
- Gear upgrades remembers whether you can wear an item and what it gives, instead of re-reading tooltips.
