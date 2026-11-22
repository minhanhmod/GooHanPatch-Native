# Phân tích gói cache_res.3106 — GooHan Hybrid

## Mẫu do người dùng cung cấp (kiểm tra tại chỗ, không đưa mẫu/khóa lên GitHub)

| Mục | Đã kiểm tra |
|---|---|
| Tên gói | cache_res.3106 |
| Kích thước | 64.716 byte |
| SHA-256 | 755c352ebae9049ce9f0bfa98035106e79bea7e3a3818f9b70c23d61f7b9f4e3 |
| Magic | \`3105PATCH\0\` |
| Envelope | Binary plist \`bplist00\` |
| Schema | **3** |
| Password protection | **False** — có public content key trong envelope |
| Nội dung | AES-256-GCM, associated data \`3105PATCH/v3/payload/<UUID>\` |
| Xác thực | Đã decrypt với public key, AES-GCM tag PASS; SHA-256 của 1 replacement payload PASS |
| Dự án | \`cache_res\` |
| Bundle ID | \`com.dts.freefiremax\` |
| Số thư mục (directory entries) | 5 |
| Số quy tắc thay thế (rules) | 1 |
| Kích thước replacement data | 63.056 byte |
| Đường dẫn tương đối trong gói | \`Documents/contentcache/Compulsory/ios/gameassetbundles/cache_res.GkLlYqzsX4AtTdE55sDMRh9sJOI~3D\` |
| Private flag | false |

Tệp này là dữ liệu thay thế cho app đích, không phải là engine iOS 27.2.

## Nguồn lỗi GooHan cũ

\`PatchPackageCodec.latestSchemaVersion = 2\` nên bộ giải mã cũ từ chối gói có schema 3, mặc dù header gốc \`3105PATCH\` không đổi.

## Đã cập nhật trên nhánh gohan-hybrid-ios27-test

- \`PatchProjectModels.swift\` đọc \`author\`, \`isPrivate\`, vẫn tương thích schema 1/2.
- \`PatchPackageCodec.swift\` chấp nhận **đọc** schema 3, giữ mặc định **xuất** schema 2 (không làm thay đổi định dạng export cũ). Gói schema3 private chưa được hỗ trợ; không bỏ qua ràng buộc private.
- \`PatchProjectLibrary.swift\` nhận diện \`.3106\`, lưu file nhập với đuôi \`.3106\`, KHÔNG tự đồng bộ/chỉnh sửa workspace schema3.
- \`PatchProjectsView.swift\` chọn \`.3106\` từ Files và hiển thị thông tin, **vô hiệu hóa Apply** cho schema3, giữ khả năng Restore biên nhận cũ.
- \`Info.plist\` đăng ký phần mở rộng \`.3106\`.
- \`scripts/check_3106_schema3.sh\` chạy test codec dùng gói schema3 tổng hợp *không chứa* mẫu người dùng; CI kiểm tra xác thực AES-GCM, checksum, backward compatibility. Cần CI thực thi để xác minh build.

## Chưa hoàn thành, không được tuyên bố là đã hoạt động

- Chưa có xác nhận compile iOS sau thay đổi này.
- Chưa xác minh người dùng nhập được cache_res.3106 trên iPhone.
- Chưa tích hợp engine ghi/khôi phục tương thích iOS 27.2.
- Chưa nâng Web Admin để xuất và phân phối \`.3106\`, không đổi \`3105-project-v1\` thành \`3106\` bằng cách đổi tên.
- Chưa hỗ trợ workspace schema3 private/merge settings; không cho phép Apply đến khi các kiểm tra này và quyền truy cập phù hợp hoạt động.

## Kiểm thử người dùng

1. GitHub Actions → \`Build GooHan Patch experimental IPA\` → \`gohan-hybrid-ios27-test\` → Run workflow.
2. Kiểm tra bước \`Verify 3106 schema-3 import compatibility\` báo \`GOOHAN_3106_CODEC_TEST_PASS\`.
3. Sau khi build thành công, ký và cài trên thiết bị thử, **không cài đè bản chính thức**.
4. Mở tính năng Patch Projects → Import từ ứng dụng Tệp → chọn \`cache_res.3106\`.
5. Kỳ vọng tên gói \`cache_res\` hiện ra và có chi tiết 1 rule, 5 folders; Apply đang khóa vì backend chưa đủ điều kiện.
6. Nếu nhập lỗi, gửi ảnh/log đúng lỗi; không cần gửi public content key.

Nghiên cứu định dạng dựa trên source 3106 GPL-3.0 của QuinnTang74; cần tuân thủ điều kiện giấy phép khi phân phối mã nguồn phái sinh.
