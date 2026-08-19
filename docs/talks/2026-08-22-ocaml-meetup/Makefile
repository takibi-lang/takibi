TARGET := slides
SRC    := $(TARGET).md
PDF    := $(TARGET).pdf

.PHONY: all show watch clean

all: $(PDF)

$(PDF): $(SRC)
	npx @marp-team/marp-cli@latest $(SRC) --pdf

show: $(PDF)
	evince $(PDF)

watch:
	@echo "$(SRC)" >> .watch_list
	@cat .watch_list | entr make

clean:
	rm -f $(PDF) .watch_list
