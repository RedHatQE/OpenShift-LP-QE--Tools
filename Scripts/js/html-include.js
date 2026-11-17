if (! window.__JS_HTMLinclude_isLoaded) {
    window.__JS_HTMLinclude_isLoaded = true;

    function ExecJS(funcArgs, jsStr, jsStg) {
        try {new Function(jsStr)} catch (err) {
            console.group('Syntax Error');
                console.groupCollapsed((
                    `Code in Attribute \`data-${jsStg}-js\` for ` +
                    '`html-include`:'
                ));
                    console.log(jsStr);
                console.groupEnd();
                console.error(`Error: ${err.message}`);
            console.groupEnd();
            return;
        }
        (new Function(...Object.keys(funcArgs), `
            try {${jsStr}} catch (e) {
                console.error(\`Error in data-${jsStg}-js: \${e}\`);
            }
        `))(...Object.values(funcArgs));
    }

    function RelPath2URL(ctx, urlParentPath) {
        const fltArr = [
            'a[href]', 'link[href]',
            'script[src]', 'img[src]', 'source[src]',
        ];

        for (const flt of fltArr) {
            ctx.querySelectorAll(flt).forEach((htmlElem) => {
                const attr = flt.match(/^.+?\[(.+)\]$/)[1];
                const path = htmlElem.getAttribute(attr);
                if (path) htmlElem.setAttribute(
                    attr,
                    (new URL(path, urlParentPath)).href,
                );
            });
        }
    }

    document.querySelectorAll('[data-html-include]').forEach(async (htmlElem) => {
        const fileURL = htmlElem.dataset.htmlInclude;
        const preJsStr = htmlElem.dataset.preJs;
        const modJsStr = htmlElem.dataset.modJs;
        const postJsStr = htmlElem.dataset.postJs;
        if (fileURL) {
            try {
                const rsp = await fetch(fileURL);
                if (rsp.ok) {
                    const shadowRoot = htmlElem.attachShadow({mode: 'open'});
                    const domParser = new DOMParser();
                    //  The `domParser.parseFromString()` will always
                    //  creates a complete `html` Node.
                    const htmlNode = domParser.parseFromString(
                        (await rsp.text()),
                        'text/html',
                    );

                    if (preJsStr) ExecJS({host: htmlElem}, preJsStr, 'pre');
                    RelPath2URL(htmlNode, (new URL('.', fileURL)).href);
                    if (modJsStr) ExecJS({html: htmlNode}, modJsStr, 'mod');
                    //  For security reason, the `<script>` elements inside will NOT be run.
                    shadowRoot.innerHTML = htmlNode.documentElement.outerHTML;
                    //  Trick to activate the `<script>` elements.
                    for (const inertScr of Array.from(shadowRoot.querySelectorAll('script'))) {
                        const execScr = document.createElement('script');
                        for (const attr of inertScr.attributes)
                            execScr.setAttribute(attr.name, attr.value);
                        execScr.textContent = inertScr.textContent;
                        inertScr.replaceWith(execScr);
                        if (execScr.src) {
                            //  For external scripts, we must wait for them to load before continuing.
                            //  This ensures scripts that depend on each other run in the correct order.
                            await new Promise((resolve) => {
                                execScr.onload = resolve;
                                execScr.onerror = resolve;  //  Continue even if a script fails.
                            });
                        }
                    }
                    if (postJsStr) ExecJS(
                        {host: htmlElem, shadow: shadowRoot},
                        postJsStr, 'post',
                    );

                    shadowRoot.dispatchEvent(new CustomEvent(
                        'html-include:shadow-loaded',
                        {
                            bubbles: true,
                            composed: true,
                            detail: {shadowRoot},
                        },
                    ));
                } else {
                    htmlElem.textContent =
                        `Error: Could not load \`${fileURL}\` (${rsp.status}).`;
                }
            } catch (err) {
                htmlElem.textContent = `Error: ${err.message}`;
            }
        }
    });
}
