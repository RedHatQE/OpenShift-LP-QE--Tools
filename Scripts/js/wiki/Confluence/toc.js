/***
Table of Contents Generator
Automatically generates a Confluence-style ToC from page headers.
***/

class TableOfContents {
    constructor(options = {}) {
        this.options = {
            tocSelector: options.tocSelector || '#toc',
            contentSelector: options.contentSelector || 'article',
            headingSelector: options.headingSelector || 'h1, h2, h3, h4, h5, h6',
            minLevel: options.minLevel || 1, // Start from h1 by default
            maxLevel: options.maxLevel || 6, // End at h6 by default
            tocTitle: options.tocTitle || 'Table of Contents',
            numbered: options.numbered !== false, // Enable numbering by default
            smoothScroll: options.smoothScroll !== false,
            highlightOnScroll: options.highlightOnScroll !== false,
        };

        this.headings = [];
        this.tocElement = null;
    }

    //  Initialize ToC generation.
    Init() {
        this.tocElement = document.querySelector(this.options.tocSelector);
        if (!this.tocElement) {
            console.warn(`ToC container "${this.options.tocSelector}" not found`);
            return;
        }

        const content = document.querySelector(this.options.contentSelector);
        if (!content) {
            console.warn(`Content container "${this.options.contentSelector}" not found`);
            return;
        }

        this.CollectHeadings(content);
        if (this.headings.length === 0) {
            console.info('No headings found to generate ToC');
            return;
        }

        this.GenerateToc();

        if (this.options.smoothScroll) {
            this.EnableSmoothScroll();
        }

        if (this.options.highlightOnScroll) {
            this.EnableScrollHighlight();
        }
    }

    //  Collect all relevant headings from content.
    CollectHeadings(content) {
        const headings = content.querySelectorAll(this.options.headingSelector);

        headings.forEach((heading, index) => {
            const level = parseInt(heading.tagName.substring(1));

            // Filter by min/max level.
            if (level < this.options.minLevel || level > this.options.maxLevel) {
                return;
            }

            // Generate ID if not present.
            if (!heading.id) {
                heading.id = this.GenerateId(heading.textContent, index);
            }

            this.headings.push({
                element: heading,
                id: heading.id,
                text: heading.textContent.trim(),
                level: level,
            });
        });
    }

    //  Generate a URL-friendly ID from text.
    GenerateId(text, index) {
        const base = text
            .toLowerCase()
            .replace(/[^\w\s-]/g, '')
            .replace(/\s+/g, '-')
            .replace(/--+/g, '-')
            .trim();

        return base || `heading-${index}`;
    }

    //  Generate ToC HTML structure.
    GenerateToc() {
        const nav = document.createElement('nav');
        nav.className = 'toc-nav';
        nav.setAttribute('role', 'navigation');
        nav.setAttribute('aria-label', 'Table of Contents');

        // Add title.
        const title = document.createElement('div');
        title.className = 'toc-title';
        title.textContent = this.options.tocTitle;
        nav.appendChild(title);

        // Build nested list.
        const list = this.BuildNestedList(this.headings);
        nav.appendChild(list);

        this.tocElement.appendChild(nav);
    }

    //  Build nested list structure from flat heading array.
    BuildNestedList(headings) {
        const root = document.createElement('ul');
        root.className = this.options.numbered
            ? 'toc-list toc-list-root toc-numbered'
            : 'toc-list toc-list-root';

        const stack = [{ level: this.options.minLevel - 1, element: root, tocDepth: 0 }];

        headings.forEach(heading => {
            // Find the appropriate parent level.
            while (stack.length > 1 && stack[stack.length - 1].level >= heading.level) {
                stack.pop();
            }

            const parent = stack[stack.length - 1];
            const tocDepth = parent.tocDepth + 1; // ToC nesting depth (1, 2, 3...)

            const li = document.createElement('li');
            li.className = `toc-item toc-level-${tocDepth}`;

            const link = document.createElement('a');
            link.href = `#${heading.id}`;
            link.textContent = heading.text;
            link.className = 'toc-link';
            link.dataset.target = heading.id;

            li.appendChild(link);

            // Create nested list if needed.
            if (stack[stack.length - 1].level < heading.level - 1) {
                // Need intermediate lists for skipped levels.
                let currentParent = parent.element;
                let currentTocDepth = tocDepth;
                for (let l = parent.level + 1; l < heading.level; l++) {
                    currentTocDepth++;
                    const intermediateUl = document.createElement('ul');
                    intermediateUl.className = 'toc-list';
                    const intermediateLi = document.createElement('li');
                    intermediateLi.className = 'toc-item-empty';
                    intermediateLi.appendChild(intermediateUl);
                    currentParent.appendChild(intermediateLi);
                    currentParent = intermediateUl;
                    stack.push({ level: l, element: currentParent, tocDepth: currentTocDepth });
                }
            }

            parent.element.appendChild(li);

            // Check if next heading is deeper - if so, add nested list.
            const nextIndex = headings.indexOf(heading) + 1;
            if (nextIndex < headings.length && headings[nextIndex].level > heading.level) {
                const nestedUl = document.createElement('ul');
                nestedUl.className = 'toc-list';
                li.appendChild(nestedUl);
                stack.push({ level: heading.level, element: nestedUl, tocDepth: tocDepth });
            }
        });

        return root;
    }

    //  Enable smooth scrolling to anchors.
    EnableSmoothScroll() {
        this.tocElement.addEventListener('click', (e) => {
            if (e.target.matches('.toc-link')) {
                e.preventDefault();
                const targetId = e.target.dataset.target;
                const targetElement = document.getElementById(targetId);

                if (targetElement) {
                    targetElement.scrollIntoView({
                        behavior: 'smooth',
                        block: 'start',
                    });

                    // Update URL hash without jumping.
                    history.pushState(null, null, `#${targetId}`);
                }
            }
        });
    }

    //  Highlight current section in ToC while scrolling.
    EnableScrollHighlight() {
        let ticking = false;

        const updateActiveLink = () => {
            const scrollPos = window.scrollY + 100; // Offset for better UX.

            let activeHeading = null;

            // Find the current heading.
            for (let i = this.headings.length - 1; i >= 0; i--) {
                if (this.headings[i].element.offsetTop <= scrollPos) {
                    activeHeading = this.headings[i];
                    break;
                }
            }

            // Update active class.
            this.tocElement.querySelectorAll('.toc-link').forEach(link => {
                link.classList.remove('toc-active');
            });

            if (activeHeading) {
                const activeLink = this.tocElement.querySelector(
                    `.toc-link[data-target="${activeHeading.id}"]`
                );
                if (activeLink) {
                    activeLink.classList.add('toc-active');
                }
            }

            ticking = false;
        };

        window.addEventListener('scroll', () => {
            if (!ticking) {
                window.requestAnimationFrame(updateActiveLink);
                ticking = true;
            }
        });

        // Initial update.
        updateActiveLink();
    }
}

// Auto-initialize on DOM ready.
if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => {
        new TableOfContents().Init();
    });
} else {
    new TableOfContents().Init();
}

// Export for manual initialization.
export default TableOfContents;
