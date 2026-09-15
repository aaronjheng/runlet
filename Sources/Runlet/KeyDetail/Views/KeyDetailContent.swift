import SwiftUI

// MARK: - Key Detail Content

/// Type-specific detail bodies for `KeyDetailView` (string/hash/list/set/zset
/// plus the generic fallback). Kept in an extension of the main view so the
/// state properties stay owned by `KeyDetailView.swift`.
extension KeyDetailView {
    @ViewBuilder
    func detailContent(key: RedisKeyEntry) -> some View {
        @Bindable var tab = tab

        switch tab.keyType {
        case "string":
            StringDetailView(
                key: key.key,
                value: tab.keyDetail,
                format: $tab.stringValueFormat,
                onSave: { value in
                    guardProductionWrite(
                        title: "Overwrite Value?",
                        message: "This will overwrite the value of \"\(key.key)\" on a production server. This action cannot be undone.",
                        confirmText: "OVERWRITE",
                        confirmButtonTitle: "Overwrite"
                    ) {
                        Task {
                            await tab.updateStringValue(key: key.key, value: value)
                            await tab.refreshSelectedKey()
                        }
                    }
                }
            )

        case "hash":
            HashDetailView(
                key: key.key,
                rows: tab.keyDetailRows,
                totalCount: tab.keyDetailTotalCount ?? key.length,
                searchText: tab.keyDetailSearchText,
                hasMoreRows: tab.keyDetailHasMoreRows,
                isProduction: isProduction,
                onSearch: { text in
                    Task { await tab.searchSelectedKeyDetail(text) }
                },
                onLoadMore: {
                    Task { await tab.loadMoreSelectedKeyDetailRows() }
                },
                onAddField: { showingAddHashField = true },
                onSaveField: { field, value in
                    guardProductionWrite(
                        title: "Overwrite Field?",
                        message: "This will overwrite field \"\(field)\" of \"\(key.key)\""
                            + "on a production server. This action cannot be undone.",
                        confirmText: "OVERWRITE",
                        confirmButtonTitle: "Overwrite"
                    ) {
                        Task {
                            await tab.updateHashField(key: key.key, field: field, value: value)
                            await tab.refreshSelectedKey()
                        }
                    }
                },
                onDeleteField: { field in
                    Task {
                        await tab.deleteHashField(key: key.key, field: field)
                        await tab.refreshSelectedKey()
                    }
                }
            )
            .sheet(isPresented: $showingAddHashField) {
                AddHashFieldSheet(
                    key: key.key,
                    field: $newHashField,
                    value: $newHashValue,
                    onSave: { field, value in
                        showingAddHashField = false
                        guardProductionWrite(
                            title: "Add Field?",
                            message: "This will add field \"\(field)\" to \"\(key.key)\" on"
                                + "a production server. This action cannot be undone.",
                            confirmText: "ADD",
                            confirmButtonTitle: "Add Field"
                        ) {
                            Task {
                                await tab.addHashField(key: key.key, field: field, value: value)
                                await tab.refreshSelectedKey()
                            }
                        }
                    },
                    onCancel: { showingAddHashField = false }
                )
                .presentationSizing(.form)
            }

        case "list":
            ListDetailView(
                key: key.key,
                rows: tab.keyDetailRows,
                totalCount: tab.keyDetailTotalCount ?? key.length,
                order: tab.keyDetailOrder,
                hasMoreRows: tab.keyDetailHasMoreRows,
                isProduction: isProduction,
                onLoadMore: {
                    Task { await tab.loadMoreSelectedKeyDetailRows() }
                },
                onOrderChange: { order in
                    Task { await tab.updateSelectedKeyOrder(order) }
                },
                onAddElement: { showingAddListElement = true },
                onSaveElement: { index, value in
                    guardProductionWrite(
                        title: "Overwrite Element?",
                        message: "This will overwrite element \(index) of \"\(key.key)\""
                            + "on a production server. This action cannot be undone.",
                        confirmText: "OVERWRITE",
                        confirmButtonTitle: "Overwrite"
                    ) {
                        Task {
                            await tab.updateListElement(key: key.key, index: index, value: value)
                            await tab.refreshSelectedKey()
                        }
                    }
                },
                onDeleteElement: { index, _ in
                    Task {
                        await tab.deleteListElement(key: key.key, index: index)
                        await tab.refreshSelectedKey()
                    }
                }
            )
            .sheet(isPresented: $showingAddListElement) {
                AddListElementSheet(
                    key: key.key,
                    value: $newListElement,
                    position: $newListInsertPosition,
                    onSave: { value, position in
                        showingAddListElement = false
                        guardProductionWrite(
                            title: "Add Element?",
                            message: "This will add an element to \"\(key.key)\" on a production server. This action cannot be undone.",
                            confirmText: "ADD",
                            confirmButtonTitle: "Add Element"
                        ) {
                            Task {
                                await tab.addListElement(key: key.key, value: value, tail: position == .tail)
                                await tab.refreshSelectedKey()
                            }
                        }
                    },
                    onCancel: { showingAddListElement = false }
                )
                .presentationSizing(.form)
            }

        case "set":
            SetDetailView(
                key: key.key,
                rows: tab.keyDetailRows,
                totalCount: tab.keyDetailTotalCount ?? key.length,
                searchText: tab.keyDetailSearchText,
                hasMoreRows: tab.keyDetailHasMoreRows,
                isProduction: isProduction,
                onSearch: { text in
                    Task { await tab.searchSelectedKeyDetail(text) }
                },
                onLoadMore: {
                    Task { await tab.loadMoreSelectedKeyDetailRows() }
                },
                onAddMember: { showingAddSetMember = true },
                onDeleteMember: { member in
                    Task {
                        await tab.deleteSetMember(key: key.key, member: member)
                        await tab.refreshSelectedKey()
                    }
                }
            )
            .sheet(isPresented: $showingAddSetMember) {
                AddSetMemberSheet(
                    key: key.key,
                    member: $newSetMember,
                    onSave: { member in
                        showingAddSetMember = false
                        guardProductionWrite(
                            title: "Add Member?",
                            message: "This will add member \"\(member)\" to \"\(key.key)\" on"
                                + "a production server. This action cannot be undone.",
                            confirmText: "ADD",
                            confirmButtonTitle: "Add Member"
                        ) {
                            Task {
                                await tab.addSetMember(key: key.key, member: member)
                                await tab.refreshSelectedKey()
                            }
                        }
                    },
                    onCancel: { showingAddSetMember = false }
                )
                .presentationSizing(.form)
            }

        case "zset":
            ZSetDetailView(
                key: key.key,
                rows: tab.keyDetailRows,
                totalCount: tab.keyDetailTotalCount ?? key.length,
                searchText: tab.keyDetailSearchText,
                order: tab.keyDetailOrder,
                hasMoreRows: tab.keyDetailHasMoreRows,
                isProduction: isProduction,
                onSearch: { text in
                    Task { await tab.searchSelectedKeyDetail(text) }
                },
                onOrderChange: { order in
                    Task { await tab.updateSelectedKeyOrder(order) }
                },
                onLoadMore: {
                    Task { await tab.loadMoreSelectedKeyDetailRows() }
                },
                onAddMember: { showingAddZSetMember = true },
                onSaveMember: { member, score in
                    guardProductionWrite(
                        title: "Overwrite Score?",
                        message: "This will overwrite the score of member \"\(member)\" in"
                            + "\"\(key.key)\" on a production server. This action cannot be undone.",
                        confirmText: "OVERWRITE",
                        confirmButtonTitle: "Overwrite"
                    ) {
                        Task {
                            await tab.updateZSetScore(key: key.key, member: member, score: score)
                            await tab.refreshSelectedKey()
                        }
                    }
                },
                onDeleteMember: { member in
                    Task {
                        await tab.deleteZSetMember(key: key.key, member: member)
                        await tab.refreshSelectedKey()
                    }
                }
            )
            .sheet(isPresented: $showingAddZSetMember) {
                AddZSetMemberSheet(
                    key: key.key,
                    member: $newZSetMember,
                    score: $newZSetScore,
                    onSave: { member, score in
                        showingAddZSetMember = false
                        guardProductionWrite(
                            title: "Add Member?",
                            message: "This will add member \"\(member)\" to \"\(key.key)\" on"
                                + "a production server. This action cannot be undone.",
                            confirmText: "ADD",
                            confirmButtonTitle: "Add Member"
                        ) {
                            Task {
                                await tab.addZSetMember(key: key.key, member: member, score: score)
                                await tab.refreshSelectedKey()
                            }
                        }
                    },
                    onCancel: { showingAddZSetMember = false }
                )
                .presentationSizing(.form)
            }

        default:
            if tab.keyDetailRows.isEmpty {
                emptyValueView
            } else {
                genericRowsView
            }
        }
    }
}
