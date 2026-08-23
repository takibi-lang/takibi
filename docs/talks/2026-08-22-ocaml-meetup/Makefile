TARGET := slides
SRC    := $(TARGET).md
PDF    := $(TARGET).pdf
HTML   := $(TARGET).html
THEME  := ../theme/takibi.css
IMAGES := ../../../img/takibi-icon-v3.png ../../../img/takibi-icon-back-v3.png
ASSETS := assets/demo.mp4 assets/human-on-the-loop.svg assets/kernel-learning-loop.svg
DIST   := dist
DIST_ASSETS := $(DIST)/assets
MARP   := npx -y @marp-team/marp-cli@latest $(SRC) --theme-set $(THEME) --allow-local-files --html

.PHONY: all show html pdf bundle clean

all: show

show:
	$(MARP) --preview

html: $(HTML)

$(HTML): $(SRC) $(THEME) $(IMAGES) $(ASSETS)
	$(MARP) -o $@

pdf: $(SRC) $(THEME) $(IMAGES) $(ASSETS)
	$(MARP) --pdf

# Create a portable directory for a web server or blog repository. Marp
# inlines the shared CSS but preserves its source-relative image URLs, so the
# two substitutions below retarget only those shared images to the copied
# bundle. Talk-local Markdown assets already use assets/... in both preview
# and bundle layouts.
bundle: $(SRC) $(THEME) $(IMAGES) $(ASSETS)
	mkdir -p $(DIST_ASSETS)
	$(MARP) -o $(DIST)/index.html
	cp $(ASSETS) $(DIST_ASSETS)/
	cp $(IMAGES) $(DIST_ASSETS)/
	sed -i \
		-e 's#../../../img/takibi-icon-v3.png#assets/takibi-icon-v3.png#g' \
		-e 's#../../../img/takibi-icon-back-v3.png#assets/takibi-icon-back-v3.png#g' \
		$(DIST)/index.html
	@if grep -q '../../../img/takibi-icon' $(DIST)/index.html; then \
		echo "ERROR: bundle still contains repository-relative image URLs"; \
		exit 1; \
	fi

clean:
	rm -f $(PDF) $(HTML)
	rm -rf $(DIST)
