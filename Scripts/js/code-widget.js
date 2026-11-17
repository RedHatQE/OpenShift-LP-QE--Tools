if (! window.__JS_CodeWidget_isLoaded) {
    window.__JS_CodeWidget_isLoaded = true;

    function IsArrayOf1(o) {
        return ((o instanceof Array) && (o.length === 1));
    }

    function IsPlainObject(o) {
        return (o && (
            (o.constructor === Object) ||
            (o.constructor === undefined)
        ));
    }

    function BuildSelectElem(elem, src) {
        for (let e of src) {
            let v = ''
            let attr = {};
            let dis = false;
            let sel = false;
            if (IsArrayOf1(e)) {
                e = e[0];
                sel = true;
            }
            if (IsPlainObject(e) && Object.keys(e).length) {
                attr = e.attr ?? {};
                v = String(e.val ?? '');
                e = String(e.txt ?? (e.val ?? ''));
            } else {
                if ((e instanceof Array) && e.length) {
                    v = String(e[0]);
                    if (e.length === 1) e = String(e[0]);
                    else e = String(e[1]);
                }
                dis = true;
            }
            if ((typeof e === 'string')) {
                const opt = document
                    .createElement('option');
                for (const k in attr) opt.setAttribute(k, String(attr[k]));
                opt.value = v;
                if (dis) opt.disabled = true;
                if (sel) opt.setAttribute('selected', '');
                opt.textContent = e;
                elem.appendChild(opt);
            }
        }
    }

    function SetTextareaWithProps(elem, val) {
        let nextNLpos = val.indexOf('\n');
        if (nextNLpos !== -1) {
            //  Check for JSON properties on first line.
            try {
                for (const [pKey, pVal] of Object.entries(
                    JSON.parse(val.substring(0, nextNLpos)),
                )) elem.setAttribute(pKey, String(pVal));
            } catch (err) {
                console.error((
                    'Failed to parse string as JSON ' +
                    'for `textarea` Element\'s Properties' +
                    `:${val.substring(0, nextNLpos)}: ${err}`
                ));
            }
            elem.textContent = val.substring(++nextNLpos);
        } else {
            elem.textContent = val;
        }
    }

    function UpdCodeBlock(block, srcObj) {
        const varVals = {};

        switch (true) {
          case (srcObj instanceof Element):
            varVals[srcObj.dataset.var] = srcObj.value;
            break;
          case (srcObj instanceof NodeList):
            srcObj.forEach((inputDiv) => {
                inputDiv.querySelectorAll((
                    'input[data-var], ' +
                    'select[data-var], ' +
                    'textarea[data-var]'
                )).forEach((input) => {
                    varVals[input.dataset.var] = input.value;
                });
            });
            break;
        }

        block.querySelectorAll(
            '.cw-cls--code-block span[data-var]',
        ).forEach((span) => {
            const varName = span.dataset.var;
            if (varVals.hasOwnProperty(varName)) {
                let value = varVals[varName];
                if (span.dataset.leftPad) {
                    const padding = span.dataset.leftPad;
                    value = value.split('\n')
                        .map(line => (padding + line))
                        .join('\n');
                }
                span.textContent = value;
            }
        });
    }

    function UpdInputDivs(block, grpOptsSel, updCB=true) {
        let grpOptsVal;
        try {
            grpOptsVal = JSON.parse((
                grpOptsSel.options[grpOptsSel.selectedIndex]
                    .dataset.grpOptsVal ??
                '{}'
            ));
        } catch (err) {
            console.error((
                'Failed to parse `data-grp-opts-val` JSON for ' +
                `\`.cw-cls--grp-opts[data-var="${grpOptsSel.dataset.var}"]/` +
                `${grpOptsSel.options[grpOptsSel.selectedIndex].value}\`` +
                `:${
                    grpOptsSel.options[grpOptsSel.selectedIndex]
                        .dataset.grpOptsVal
                }: ${err}`
            ));
        }

        for (let [key, val] of Object.entries(grpOptsVal)) {
            block.querySelectorAll((
                `input[data-var="${key}"], ` +
                `select[data-var="${key}"], ` +
                `textarea[data-var="${key}"]`
            )).forEach((elem) => {
                let newElem;
                switch (true) {
                  case (
                    (typeof val === 'string') ||
                    (
                        IsArrayOf1(val) &&
                        (typeof val[0] === 'string')
                    )
                  ):
                    let ro = false;
                    if ((val instanceof Array)) {
                        val = val[0];
                        ro = true;
                    }
                    if (val[0] === '\n') {
                        //  Multi-line value: create `textarea`.
                        newElem = document.createElement('textarea');
                        newElem.dataset.var = key;
                        SetTextareaWithProps(newElem, val.substring(1));
                        if (ro) newElem.readOnly = true;
                    } else {
                        //  Single-line value: create `input`.
                        newElem = Object.assign(
                            document.createElement('input'),
                            {type: 'text'},
                        );
                        newElem.dataset.var = key;
                        newElem.setAttribute('value', val);
                        if (ro) newElem.readOnly = true;
                    }
                    elem.replaceWith(newElem);
                    break;
                  case ((val instanceof Array)):
                    newElem = document.createElement('select');
                    newElem.classList.add('cw-cls--opt');
                    newElem.dataset.var = key;
                    BuildSelectElem(newElem, val);
                    elem.replaceWith(newElem);
                    break;
                }
            });
        }

        if (updCB) UpdCodeBlock(
            block,
            block.querySelectorAll('.cw-cls--inputs'),
        );
    }

    function AttToInputEvent(ctx) {
        ctx.querySelectorAll('.code-widget').forEach((block) => {
            let cfgMap = {def: {}, set: {}}
            try {
                Object.assign(
                    cfgMap,
                    JSON.parse((
                        block.querySelector('.cw-cls--config')?.textContent ??
                        '{}'
                    )),
                );
            } catch (err) {
                console.error((
                    'Failed to parse `.cw-cls--config` JSON for ' +
                    `\`.code-widget#${block.id}\`` +
                    `:${block.querySelector(
                        '.cw-cls--config',
                    )?.textContent}: ` +
                    `${err}`
                ));
                return;
            }
            const allInputDivs = block.querySelectorAll('.cw-cls--inputs');
            allInputDivs.forEach((inputDiv) => {
                inputDiv.querySelectorAll((
                    'input[data-var], ' +
                    'select[data-var], ' +
                    'textarea[data-var]'
                )).forEach((input) => {
                    const varName = input.dataset.var;
                    if (cfgMap.set.hasOwnProperty(varName)) {
                        let varVal = cfgMap.set[varName];
                        switch (true) {
                          case input.matches('select.cw-cls--grp-opts'):
                            if (
                                IsPlainObject(varVal) &&
                                Object.keys(varVal).length
                            ) {
                                input.innerHTML = '';
                                BuildSelectElem(input, [varVal]);
                                UpdInputDivs(block, input, false);
                                varVal = String(varVal.val ?? '');
                            }
                            break;
                        }
                        input.closest('label')?.remove();
                        if ((typeof varVal === 'string'))
                            block.querySelectorAll(
                                `.cw-cls--code-block span[data-var="${
                                    varName
                                }"]`,
                            ).forEach((span) => {
                                if (span.dataset.leftPad) {
                                    const padding = span.dataset.leftPad;
                                    varVal = varVal.split('\n')
                                        .map(line => (padding + line))
                                        .join('\n');
                                }
                                span.replaceWith(
                                    document.createTextNode(varVal),
                                );
                            });
                        if (! inputDiv.querySelector((
                            'input[data-var], ' +
                            'select[data-var], ' +
                            'textarea[data-var]'
                        ))) inputDiv.remove();
                    } else if (cfgMap.def.hasOwnProperty(varName)) {
                        let val = cfgMap.def[varName];
                        let ro = false;
                        switch (true) {
                          case (input instanceof HTMLInputElement):
                            if (IsArrayOf1(val)) {
                                val = val[0];
                                ro = true;
                            }
                            if ((typeof val === 'string'))
                                input.setAttribute('value', val);
                            if (ro) input.readOnly = true;
                            break;
                          case (input instanceof HTMLTextAreaElement):
                            if (IsArrayOf1(val)) {
                                val = val[0];
                                ro = true;
                            }
                            if ((typeof val === 'string'))
                                SetTextareaWithProps(input, val);
                            if (ro) input.readOnly = true;
                            break;
                          case (
                            (input instanceof HTMLSelectElement) &&
                            (val instanceof Array)
                          ):
                            input.innerHTML = '';
                            BuildSelectElem(input, val);
                            break;
                        }
                    }
                });
            });

            allInputDivs.forEach((inputDiv) => {
                //  Listen for `input` Events on this block's input container.
                inputDiv.addEventListener(
                    'input',
                    (event) => UpdCodeBlock(block, event.target),
                );
            });

            //  Run once, on load, to set initial values.
            UpdCodeBlock(block, allInputDivs);

            block.querySelectorAll('.cw-cls--grp-opts')
                .forEach((grpOptsSel) => {
                    grpOptsSel.addEventListener(
                        'input',
                        (event) => UpdInputDivs(block, event.target),
                    );

                    //  Trigger once, on load, to set initial values.
                    grpOptsSel.dispatchEvent(new Event('input'));
                });
        });

        //  Dispatch complete Event notifier.
        const isShadowDOM = ctx instanceof ShadowRoot;
        ctx.dispatchEvent(new CustomEvent((
            isShadowDOM
                ? 'code-widget:shadow-initialized'
                : 'code-widget:document-initialized'
        ), {
            bubbles: true,
            composed: true,
            detail: {
                context: (isShadowDOM ? 'shadow' : 'document'),
                root: ctx
            }
        }));
    }


/*
--------------------------------------------------------------------------------
User Library Functions.
--------------------------------------------------------------------------------
*/
    function UsrLib_OvrCfg(ctx, ovrCfgMap) {
        ctx = ctx ?? document;
        for (const [cwID, ovrCfg] of Object.entries(ovrCfgMap)) {
            const cwElem = ctx.getElementById(cwID);
            if (! cwElem) continue;
            const cfgElem = cwElem.querySelector('.cw-cls--config');
            const newCfgMap = JSON.parse((cfgElem?.textContent ?? '{}'));
            for (const key in ovrCfg) {
                newCfgMap[key] = Object.assign(
                    (newCfgMap[key] ?? {}),
                    ovrCfg[key],
                );
            };
            for (const key in newCfgMap.set)
                if (newCfgMap.def.hasOwnProperty(key))
                    delete newCfgMap.def[key];
            cfgElem.textContent = JSON.stringify(newCfgMap, null, 2);
        }
    }
    window.CodeWidget__UsrLib_OvrCfg = UsrLib_OvrCfg;   //  Expose it globally.
/*----------------------------------------------------------------------------*/


    AttToInputEvent(document);
    document.addEventListener('html-include:shadow-loaded', (event) => {
        AttToInputEvent(event.detail.shadowRoot);
    });
}
