# SPDX-License-Identifier: GPL-2.0
CFLAGS ?= -O2 -Wall -Wextra

dio_fallback_race: dio_fallback_race.c
	$(CC) $(CFLAGS) -pthread -o $@ $<

clean:
	rm -f dio_fallback_race

.PHONY: clean
