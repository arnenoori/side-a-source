// replace() keeps the old /how/ address out of the back stack.
location.replace(new URL(`../${location.search}#how`, location.href));
