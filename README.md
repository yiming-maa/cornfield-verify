# cornfield-verify

玉米地里（UIUC 校园匿名社区 iOS App）的 **UIUC 邮箱验证模块**源码。公开它只为一件事：让你自己核对「**你的学校邮箱和你的账号之间，数据库里没有那一行**」。

这不是一个能单独运行的项目。这里的每个文件都是从玉米地里的生产后端仓库（Rails 8）逐字复制出来的，来源 commit 记在 [`SOURCE.txt`](SOURCE.txt)。

## 它证明什么

验证流程里，服务器只把邮箱的 HMAC 哈希写进一张表 `verified_emails`。这张表除了哈希和时间，没有别的列，没有外键。账号表 `profiles` 上只有一个布尔值 `is_verified`。

```
POST send_verification_code {email}          POST verify_email {email, code}
  h = HMAC(pepper, email)                      h = HMAC(pepper, email)
  verified_emails ∋ h ?  → 409 已验证过         code(h) 有效? 否 → 400
  INSERT verification_codes(h, code)           verified_emails ∋ h ? → 409
  Resend.send(email, code)                     TX: INSERT verified_emails(h)
    ↑ 明文邮箱只在这一次请求的内存里                UPDATE profiles SET is_verified = true
                                                   DELETE verification_codes WHERE h
```

结果：拿到整个数据库的人，最多知道「这个邮箱验证过」，对不上是哪个账号。管理员后台也一样，因为查询不到不存在的数据。

同一个邮箱只能验证一个账号。第二次验证会收到 409，服务器不会告诉你（也不知道）第一个账号是谁。注销前可以用验证码把邮箱从 `verified_emails` 里放出来（`release_verified_email`），之后能重新验证一个新账号。

## 看哪几个文件

| 文件 | 看什么 |
|---|---|
| [`app/services/email_hasher.rb`](app/services/email_hasher.rb) | HMAC-SHA256 加服务端 pepper，生产环境缺 pepper 直接报错 |
| [`app/models/verified_email.rb`](app/models/verified_email.rb) | 只有 `email_hash` 主键，没有账号列 |
| [`app/controllers/api/v1/profiles_controller.rb`](app/controllers/api/v1/profiles_controller.rb) | `send_verification_code` / `verify_email` / `release_verified_email` 三个动作 |
| [`db/migrate/20260903000000_create_verified_emails_and_relax_email_columns.rb`](db/migrate/20260903000000_create_verified_emails_and_relax_email_columns.rb) | 建表语句，PostgREST 匿名角色被撤销读写 |
| [`spec/db/unlinkability_spec.rb`](spec/db/unlinkability_spec.rb) | **结构不变量**：任何一张表不得同时含账号列和邮箱列。每次 CI 跑 |
| [`spec/requests/api/v1/profiles_spec.rb`](spec/requests/api/v1/profiles_spec.rb) | 请求级测试，含「日志里 user_id 和邮箱不同行」 |
| [`docs/privacy-promise.md`](docs/privacy-promise.md) | App 内「我们看不到你」页面的原文 |

## 说实话的边界

开源代码只能证明**设计**如此。以下是它证明不了的，以及我们如何处理：

1. **线上跑的是不是这份代码。** 你没法从外部验证。我们能做的是让 `SOURCE.txt` 指向生产仓库的 commit，并在每次部署后同步这里。这是信任，不是证明。
2. **验证的那一秒服务器同时知道邮箱和账号。** 代码里能看到我们不记下来（`profiles_controller.rb` 的 `verify_email`，日志只写 user_id）。但这是「不记」，不是「不知道」。
3. **发验证码的邮件服务（Resend）能看到收件邮箱。** 它看不到账号。Resend 的投递日志保留期由 Resend 决定。
4. **pepper 泄露加数据库泄露**：攻击者可以把全校邮箱逐个哈希，得到「哪些邮箱验证过玉米地里」。仍然对不上账号，因为没有那一行。
5. **登录提供商知道你登录过。** 账号用 Apple 或 Google 登录，`auth.users` 里存的是他们给的随机 ID 和登录邮箱。用 Apple 登录并选「隐藏邮箱」，我们连登录邮箱都拿不到。用 Gmail 登录，我们能看到你的 Gmail，看不到它和学校邮箱的关系。
6. **2026 年 9 月之前注册的老账号。** 早期版本允许直接用 illinois.edu 邮箱登录，这些账号的学校邮箱仍存在登录提供商的 `auth.users` 表里。这批账号数量很少，目前**没有处理**。新版 App 已拒绝用 illinois.edu 邮箱登录。
7. **过渡期的遗留列。** `profiles.uiuc_email`、`profiles.email_hash`、`verification_codes.email` 三列在 `unlinkability_spec.rb` 的 `LEGACY_ALLOWLIST` 里。它们正在按 expand → migrate → contract 三步删除（见 `lib/tasks/privacy.rake`），删完后 allowlist 必须为空，spec 会强制这一点。
8. **你写了什么，我们看得到。** 看不到你是谁，不等于看不到你写了什么。

## 怎么核对

1. 在 `verified_emails` 的 migration 里确认没有 `user_id` 或任何引用 `profiles` 的列。
2. 在 `unlinkability_spec.rb` 里读那条正则：任何表名下同时出现账号列和含 `email` 的列都算违规。
3. 全文搜索 `email`，确认它只出现在：哈希前的一次 `normalize`、发给 Resend 的请求体、以及上面第 7 条列出的遗留列。
4. 读 `verify_email` 的事务：写 `verified_emails(h)`，改 `profiles.is_verified`，两条语句之间没有任何字段把 h 和 user_id 放在一起。

发现漏洞或者觉得哪句话说过头了，开 issue。

## License

MIT
