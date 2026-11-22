# Chế độ định dạng Patch 3105 / 3106 (Hybrid thử nghiệm)

## Kết quả kiểm tra source 3106

- `ThreeOneOSSix/Info.plist` khai báo cả đuôi `.3105` và `.3106`.
- `PatchPackageCodec.swift` giữ magic `3105PATCH\0`, hỗ trợ schema **1–3**.
- `PatchProjectLibrary.swift` đọc cả hai phần mở rộng, nhưng tạo gói mới là `.3106`.
- GooHan hiện tại chỉ đọc schema **1–2**, và Admin chính thức chỉ xuất bản gói `.3105` cùng kế hoạch `3105-project-v1`.

**Do đó không thể suy ra chỉ từ phần đuôi file rằng định dạng .3105 không chạy trên iOS 27, hoặc đổi tên .3105 thành .3106 sẽ chuyển đổi nội dung.** Nếu một file .3105 không nhập được 3106, cần kiểm tra lỗi thực tế, bản app và schema/nội dung gói cụ thể.

## UI đã thêm trên nhánh này

Cài đặt GooHan (sheet trong `ContentView.swift`) có ba lựa chọn:
- **Tự động:** ưu tiên thư viện `.3105` trên iOS cũ và `.3106` từ iOS 26.7+/27.x.
- **3105:** xem thư viện `.3105` dù iOS mới hơn.
- **3106:** xem thư viện `.3106` dù iOS cũ hơn.

Định dạng đã chọn chỉ **lọc danh sách gói** theo `packageFormat` do Admin trả về. Các gói có receipt đang bật vẫn hiển thị để có thể khôi phục. Lựa chọn này không thay thế sandbox/backend.

## Điều kiện an toàn

- Chưa có bộ đọc/giao dịch `.3106` trong GooHan, vì vậy nút bật gói `.3106` bị vô hiệu hóa. UI hiển thị rõ **chưa hỗ trợ**.
- Chọn `3105` trên iOS 27.2 **không kích hoạt** backend 3105 nếu bản iOS này chưa được xác minh và hỗ trợ. Các nút bật bị vô hiệu nếu `ExploitSupportPolicy` không hỗ trợ bản iOS.
- `DevicePatchService`, `PatchTransaction`, License, Admin và các receipt hiện có **không bị đổi**.
- Tuyệt đối không tự nâng cờ `worseQueryImplemented` thành true khi chưa build, ký đúng entitlement, kiểm thử quyền ghi/khôi phục thực tế.
- Thay đổi này **không** chứa bản sửa công tắc v5.12.5 mà người dùng đã hủy.

## Việc chưa hoàn thành

1. Tích hợp và kiểm tra bộ xử lý schema 3 / .3106.
2. Tích hợp backend và container resolver tương thích iOS 27.2; kiểm tra App Group entitlement sau ký.
3. Nâng API/Admin để có thể xuất bản và trả `packageFormat=3106` với biểu diễn nội dung phù hợp (không chỉ đổi tên file).
4. Test nhập gói `.3105` cụ thể bị lỗi trên 3106 để xác định nguyên nhân thực.
5. Build IPA Hybrid mới và kiểm thử trên iPhone. Chưa tuyên bố hỗ trợ Patch iOS 27.2.

## Kiểm tra tự động

GitHub Actions đã có bước `Check Hybrid iOS backend policy`, thực hiện `bash scripts/check_hybrid_backend.sh`. Script nay cũng kiểm tra Auto/3105/3106, đảm bảo khi chưa tích hợp codec thì `canApply(3106) == false`.
