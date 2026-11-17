# ProfitCrafter Forever Plus

An extended build of ProfitCrafter Forever 0.3.0 by MostlyNotBroken, for World of Warcraft: Forever. Shared with the original developer for possible integration.

The first commit is the unmodified 0.3.0 release, so `git diff` against it shows every change.

To install, the folder must be named `ProfitCrafterForever` inside `_forever_/Interface/AddOns/`.

## New

- Auction Profit and Vendor Profit wherever a profit is shown.
- Craftable at Profit, Total Auction Profit and Total Vendor Profit columns, the whole batch priced at live listings. Sells at auction and Sells to vendor for side by side.
- Recipe tooltips list each ingredient and its price. The "how many?" pop-up has Max profitable.
- Minimum profit (Settings, default 10%). Recipes below it are hidden and buying stops before a craft drops below it. The plan is then amended to match (`/pc undo` reverts it).
- Separate Only N%+ Auction profit and Only N%+ Vendor profit boxes on the recipe tables and Scout recipes. Tick both and a recipe must meet both.
- Every table sorts on every column.
- Best bets and Make me gold favour what sells: an auction craft needs today's sales to be at least half its listings. Hot sellers come first, then the rest by profit potential.
- Quick Buy (the coin on each recipe): plans the crafts that clear your minimum profit, buys the main auction material and opens the plan.
- One-click auction buying: the price is checked and confirmed at once if it still pays (Settings).
- Faster auction scans: 100 items a search (was 25), and listings that haven't changed are skipped.
- Use what's in my bank (Settings, on by default). Off: the bank is ignored entirely.
- Scout recipes read the prices of what learnable recipes make and use. Prices over 6 hours old are marked ~.
- Craft tasks give the item count when a recipe makes several ("34 Seasoned Wolf Kabob (makes 102)").
- Selling to a vendor splits stacks to sell an exact amount.
- Auction listings cheaper than a vendor are bought up to what the vendor charges.
- Your own fresh scan beats other players' prices for a minute.
- No auction craft suggestions when none sold today.
- The flight line is back (Settings), hidden while EllesmereUI's flight bar shows. Junk is left to Scrap when it's installed.
- Clearer wording: what a vendor pays you and what a vendor charges you are told apart everywhere, and Auction and Vendor are spelled out instead of AH and V.
- A price held over 10 seconds is checked again before buying.

## Fixed

- Much less stutter in the Learn list, routes, the Task Button, the task list and the window.
- Buying could go over the plan when the Auction House answered slowly.
- Vendor purchases go one at a time, each checked in your bags. Anything that doesn't arrive is reported, never bought again.
- Vendor buying missed plan changes made at the vendor.
- Typing a plan count could change the wrong recipe.
- The bank could crash with an item on the cursor.
- Secret messages in combat no longer cause errors.
- One auction purchase no longer prints several "Bought" lines.
- No Hearthstone or teleport within the zone you're in, and no travel to a stop you're already at.
- Vendor materials and crafts came in smaller batches than your bags allowed.
- The Materials table says "buying N" while a purchase is on its way, and Have shows what's in the bank, the mail or on its way.
- Scout recipes showed a profit for recipes with no known source or cost.
- Place, NPC and recipe names shared in another alphabet (e.g. Russian) are translated or left out.
- Clicking Buy on a second item before the first item's price arrived could confirm it at a price never checked.
- A refused or blocked purchase could later be taken as bought, so the plan bought too little.
- A halved retry the game blocked started over at the full amount on the next click.
- One refused purchase limited the size of every later purchase, not just that item's.
- Old live listings were still used after an item sold out or its price changed.
- Finishing crafts whose scarce materials you hold could cost more than the craft brings in.
- A short market was taken as a profit stop and cut the plan.
- Turning off Use what's in my bank forgot purchases waiting in the mail.
- The plan's bag check ignored the reagent bag, and batches counted room that reagent bag materials don't free.
- Make me gold's Your materials list skipped the half-of-listed sales rule.
- Routes could Hearthstone out and walk back for a stop in your own zone.
- "Stopped buying" could get stuck on the Task Button away from the Auction House.
- A Keep number typed on the Sell page could land on another item.
- The empty recipe list blamed the profit boxes when Can afford had hidden the rows.
- Gear upgrades now rechecks items after you learn a weapon skill.
