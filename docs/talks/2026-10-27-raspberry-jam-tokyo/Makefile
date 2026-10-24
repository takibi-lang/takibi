TARGET := slides
SRC    := $(TARGET).md
PDF    := $(TARGET).pdf
HTML   := $(TARGET).html
THEME  := ../theme/takibi.css
IMAGES := ../../../img/takibi-icon-v3.png ../../../img/takibi-icon-back-v3.png
# This deck has no talk-local figures or media.
ASSETS :=
MARP   := npx -y @marp-team/marp-cli@latest $(SRC) --theme-set $(THEME) --allow-local-files --html

# `review` renders every slide to PNG. This is the only way a slide that
# overflows its box gets found: the source looks fine, and Marp does not
# complain -- the content simply runs under the footer or off the bottom.
#
# Marp needs a real Chromium. The `chromium-browser` package on this image is
# a snap stub that cannot start inside a container ("requires the chromium
# snap to be installed"), so install one that works and point CHROME_PATH at
# it:
#
#     npx puppeteer browsers install chrome
#     make review CHROME_PATH=$HOME/.cache/puppeteer/chrome/linux-*/chrome-linux64/chrome
#
REVIEW_DIR := review
DIST := dist
DIST_ASSETS := $(DIST)/assets

.PHONY: all show html pdf bundle review clean

all: show

show:
	$(MARP) --preview

html: $(HTML)

$(HTML): $(SRC) $(THEME) $(IMAGES)
	$(MARP) -o $@

pdf: $(SRC) $(THEME) $(IMAGES)
	$(MARP) --pdf

# Create a portable, self-hosted copy for a web server or blog repository.
# Marp inlines the shared CSS but preserves its repository-relative image
# URLs, so retarget those images to copies inside the bundle. Talk-local
# assets already use assets/... in both the source and bundle layouts.
# Unlike the presentation-time targets, the bundle requires any
# talk-local assets because it is the complete published artifact.
bundle: $(SRC) $(THEME) $(IMAGES) $(ASSETS)
	mkdir -p $(DIST_ASSETS)
	$(MARP) -o $(DIST)/index.html
	$(MARP) --pdf -o $(DIST)/slides.pdf
	cp $(IMAGES) $(DIST_ASSETS)/
	sed -i \
		-e 's#../../../img/takibi-icon-v3.png#assets/takibi-icon-v3.png#g' \
		-e 's#../../../img/takibi-icon-back-v3.png#assets/takibi-icon-back-v3.png#g' \
		$(DIST)/index.html
	@if grep -q '../../../img/takibi-icon' $(DIST)/index.html; then \
		echo "ERROR: bundle still contains repository-relative image URLs"; \
		exit 1; \
	fi

review: $(SRC) $(THEME) $(IMAGES)
	mkdir -p $(REVIEW_DIR)
	$(MARP) --images png -o $(REVIEW_DIR)/slide.png

clean:
	rm -f $(PDF) $(HTML)
	rm -rf $(REVIEW_DIR) $(DIST)
