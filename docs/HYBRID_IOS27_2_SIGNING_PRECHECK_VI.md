# GooHan Hybrid iOS 27.2 — Bước kiểm tra ký IPA

**Nhánh duy nhất:** `gohan-hybrid-ios27-test`. Bản chính thức `gohan-rebrand-no3105` không đổi.

## Trạng thái đã kiểm chứng ở mức source
- Hybrid backend policy đã được build ở nhánh thử nghiệm.
- `worse_query` **chưa tích hợp**; iOS 27.2 hiện là **ứng viên tương thích**, không phải hỗ trợ đã xác minh.
- GitHub Actions tạo `GooHanPatch-experimental-unsigned.ipa` với `CODE_SIGNING_ALLOWED=NO`. File đó **không có chứng cứ về App Group entitlement sau khi ký**.
- GooHan hiện không cấu hình `CODE_SIGN_ENTITLEMENTS` hay file entitlements App Group.
- `CFBundleIdentifier` trong source hiện tại là `com.apple.mobile.MobileHouseArrest`, một định danh Apple. Để ký với App Group hợp lệ bằng tài khoản riêng, cần xem xét App ID do bạn sở hữu **trên nhánh thử nghiệm** và đánh giá tác động tới cài đè/License. Không đổi tự động.

## Kiểm tra chữ ký IPA
Từ máy Mac có Xcode Command Line Tools, sau khi ký IPA bằng công cụ của bạn:

```bash
python3 scripts/audit_signed_ipa.py /duong/dan/GooHan-Hybrid-signed.ipa
```

Đường dẫn phải trỏ tới file **đã ký**, không phải file unsigned tải từ GitHub Actions.

- `PASS: valid signature and matching App Group authorization`: chữ ký và App Group có trong provisioning profile khớp.
- `FAIL: signed application has NO App Group entitlement`: cách ký hiện tại không cung cấp quyền cần cho thử nghiệm.
- `FAIL: Signed App Groups do not match the provisioning profile`: App Group yêu cầu không được profile cho phép.
- `NOT_VERIFIED`: thiếu macOS/codesign/profile, **không được hiểu là PASS**.

Nếu dùng Windows hoặc chỉ có iPhone/eSign, công cụ không thể xác minh chữ ký giống macOS; cần kiểm tra trên Mac hoặc nhờ người có máy Mac chạy audit. Không gửi chứng chỉ hay khóa bí mật.

## Cổng kiểm thử trước tích hợp
1. Xác minh IPA thử nghiệm sau khi ký giữ đúng App Group (không dùng App ID Apple để tạo nhóm mới).
2. Chạy trên thiết bị thử iOS 27.2; xác minh mở app, License và đồng bộ Admin **mà không sửa tệp ứng dụng khác**.
3. Thử khả năng lưu/khôi phục vào vùng dữ liệu thử nghiệm được phép truy cập; nếu thất bại ghi nhận lỗi rõ ràng và không đánh dấu Patch là thành công.
4. Chỉ sau đó mới đánh giá tích hợp backend, độ tương thích `.3105`, rollback, và ràng buộc GPL-3.0 từ 3106.

## Những gì chưa thay đổi
Không thay `PatchTransaction`, `DevicePatchService`, `ContainerStore`, `LicenseManager`, Admin v5.13 hay giao diện; không thêm bản Toggle Isolation v5.12.5.

Bản công cụ là **read-only**: chỉ giải nén IPA vào thư mục tạm, đọc mã ký và profile, xóa thư mục tạm sau khi hoàn tất. Công cụ không ký lại IPA hay sửa source.
