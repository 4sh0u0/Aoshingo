// SPDX-License-Identifier: Apache-2.0
//
// 「メールアドレスを表示」 button on the support page and the privacy policy.
//
// The address is not in the HTML. When the visitor presses the button, Cloudflare Turnstile checks
// that they are not a bot, and the aoshingo-contact Worker (site/contact-worker) returns the address
// for the Turnstile token. Turnstile is loaded only after the button is pressed. While CONFIG is
// incomplete the block stays hidden, and the page offers only GitHub Issues.

(() => {
  "use strict";

  const CONFIG = {
    // Site Key of the Turnstile widget (public). See site/contact-worker/README.md.
    sitekey: "",
    // POST endpoint of the aoshingo-contact Worker.
    endpoint: "",
  };

  const TURNSTILE_URL = "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit&onload=";
  const TURNSTILE_ONLOAD = "aoshingoTurnstileLoaded";
  const LOAD_TIMEOUT_MS = 20000;
  // Must match TURNSTILE_ACTION in site/contact-worker/src/app.ts.
  const ACTION = "show-email";
  const EMAIL_PATTERN = /^[^\s@"<>()]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/;
  const SUBJECT = "Aoshingo について";

  const MESSAGES = {
    checking: "ロボットによる操作でないかを確かめています。確認の枠に指示が出たら、それに従ってください。",
    shown: "メールアドレスを表示しました。",
    failed: "確認できませんでした。もう一度ボタンを押すか、GitHub の Issue をご利用ください。",
    busy: "表示の回数が上限に達しました。1 分ほど待ってから、もう一度ボタンを押してください。",
    unavailable: "いまはメールアドレスを表示できません。時間をおいてもう一度試すか、GitHub の Issue をご利用ください。",
    blocked:
      "確認用のスクリプト（challenges.cloudflare.com）を読み込めませんでした。コンテンツブロッカーなどで止めている場合は許可するか、GitHub の Issue をご利用ください。",
    unsupported: "このブラウザーでは確認ができません。ほかのブラウザーで試すか、GitHub の Issue をご利用ください。",
  };

  if (!CONFIG.sitekey || !CONFIG.endpoint) return;

  let turnstileLoading = null;

  function loadTurnstile() {
    if (window.turnstile) return Promise.resolve(window.turnstile);
    if (!turnstileLoading) {
      turnstileLoading = new Promise((resolve, reject) => {
        const script = document.createElement("script");
        const fail = () => {
          window.clearTimeout(timer);
          turnstileLoading = null;
          script.remove();
          reject(new Error("Turnstile could not be loaded"));
        };
        const timer = window.setTimeout(fail, LOAD_TIMEOUT_MS);
        window[TURNSTILE_ONLOAD] = () => {
          window.clearTimeout(timer);
          resolve(window.turnstile);
        };
        script.src = TURNSTILE_URL + TURNSTILE_ONLOAD;
        script.addEventListener("error", fail);
        document.head.append(script);
      });
    }
    return turnstileLoading;
  }

  function setUp(root) {
    const button = root.querySelector("[data-contact-button]");
    const widget = root.querySelector("[data-contact-widget]");
    const status = root.querySelector("[data-contact-status]");
    const result = root.querySelector("[data-contact-result]");
    if (!button || !widget || !status || !result) return;

    let busy = false;
    let widgetId = null;
    let turnstile = null;

    // Clears first, so that the same message is announced again.
    const say = (message) => {
      status.textContent = "";
      window.setTimeout(() => {
        status.textContent = message;
      }, 100);
    };

    // Deferred, because this can run inside one of the widget's own callbacks.
    const removeWidget = () => {
      const id = widgetId;
      widgetId = null;
      widget.hidden = true;
      if (turnstile && id !== null) window.setTimeout(() => turnstile.remove(id), 0);
    };

    const stop = (message) => {
      removeWidget();
      busy = false;
      button.removeAttribute("aria-disabled");
      say(message);
    };

    const show = (email) => {
      removeWidget();
      const link = document.createElement("a");
      link.href = `mailto:${email}?subject=${encodeURIComponent(SUBJECT)}`;
      link.textContent = email;
      result.replaceChildren("メールアドレス：", link);
      result.hidden = false;
      say(MESSAGES.shown);
      link.focus();
      button.hidden = true;
    };

    const reveal = async (token) => {
      let response;
      try {
        response = await fetch(CONFIG.endpoint, {
          method: "POST",
          body: new URLSearchParams({ token }),
          credentials: "omit",
          cache: "no-store",
          referrerPolicy: "no-referrer",
        });
      } catch {
        stop(MESSAGES.unavailable);
        return;
      }
      if (response.status === 429) return stop(MESSAGES.busy);
      if (response.status === 403) return stop(MESSAGES.failed);
      if (!response.ok) return stop(MESSAGES.unavailable);
      const data = await response.json().catch(() => null);
      const email = data && typeof data.email === "string" ? data.email : "";
      if (!EMAIL_PATTERN.test(email)) return stop(MESSAGES.unavailable);
      show(email);
    };

    button.addEventListener("click", async () => {
      if (busy) return;
      busy = true;
      button.setAttribute("aria-disabled", "true");
      say(MESSAGES.checking);
      try {
        turnstile = await loadTurnstile();
      } catch {
        stop(MESSAGES.blocked);
        return;
      }
      widget.hidden = false;
      widgetId = turnstile.render(widget, {
        sitekey: CONFIG.sitekey,
        action: ACTION,
        language: "ja",
        theme: "auto",
        size: "flexible",
        "refresh-expired": "never",
        callback: (token) => {
          reveal(token);
        },
        "error-callback": () => {
          stop(MESSAGES.failed);
          return true;
        },
        "timeout-callback": () => stop(MESSAGES.failed),
        "unsupported-callback": () => stop(MESSAGES.unsupported),
      });
    });

    root.hidden = false;
  }

  for (const root of document.querySelectorAll("[data-contact-email]")) setUp(root);
})();
